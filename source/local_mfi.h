/*
 * local_mfi.h — load a user-provided MFi accessory certificate + key from
 * disk and use them for CarPlay auth, instead of issuing the device's own
 * BAA (DeviceIdentity) certificate over the network.
 *
 * This is the same "local certificate" path the open-source xcertplay project
 * exposes. Purpose: let Showcase authenticate offline (no 12h network refresh)
 * when the operator supplies their own accessory credential.
 *
 * Files (both DER):
 *   certificate.p7b   PKCS#7 SignedData carrying the accessory certificate.
 *                     Sent to the iPhone byte-for-byte as the cert payload.
 *   identity.pk8      unencrypted PKCS#8 private key matching that cert.
 *
 * Looked for in LOCAL_MFI_DIRS; the first directory that has BOTH files wins.
 * If neither is found, Showcase keeps its original BAA behaviour untouched.
 *
 * Wire behaviour when a local cert is active (P-256 key => MFi auth v3):
 *   iAP2  0xAA01 : param 0 = p7b bytes          (no BAA params 0x0001/0x0002)
 *   iAP2  0xAA03 : param 0 = raw r||s (64 bytes), ECDSA over the challenge,
 *                  the 32-byte challenge used directly as the digest
 *   /auth-setup  : digest = SHA256(ourPK||peerPK); response layout
 *                  pk[32] | len_be|p7b | len_be|encSig   (no baIC trailer)
 *
 * The DER-parsing half is plain C with no Apple dependencies, so
 * test/local_mfi_test.c exercises it on Linux.
 */

#ifndef SHOWCASE_LOCAL_MFI_H
#define SHOWCASE_LOCAL_MFI_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jbroot.h"

#define LOCAL_MFI_CERT_NAME  "certificate.p7b"
#define LOCAL_MFI_KEY_NAME   "identity.pk8"
#define LOCAL_MFI_MAX_FILE   (64U * 1024U)
#define LOCAL_MFI_SIG_BYTES  64   /* raw r||s for P-256 */

static const char *const LOCAL_MFI_DIRS[] = {
    "/var/jb/etc/showcase",       /* rootless (Dopamine); RootHide maps it via jb_fix */
    "/etc/showcase",              /* rootful */
    "/var/mobile/showcase-cert",  /* fallback, no root write needed */
};

/* ── tiny DER reader (plain C, no crypto libs) ──────────────────── */

typedef struct { const uint8_t *p; size_t len; } lmfi_span;

/* Read one TLV from *in. Sets *tag and value span *val, advances *in past it.
 * Supports definite-length short and long form only. */
static inline bool lmfi_der_next(lmfi_span *in, uint8_t *tag, lmfi_span *val) {
    if (in->len < 2) return false;
    const uint8_t *p = in->p;
    size_t avail = in->len;
    uint8_t t = p[0];
    if ((t & 0x1f) == 0x1f) return false;   /* multi-byte tags unused here */
    size_t hdr = 2;
    size_t length;
    if (p[1] < 0x80) {
        length = p[1];
    } else {
        size_t nbytes = p[1] & 0x7f;
        if (nbytes == 0 || nbytes > 4 || avail < 2 + nbytes) return false;
        length = 0;
        for (size_t i = 0; i < nbytes; i++) length = (length << 8) | p[2 + i];
        hdr = 2 + nbytes;
    }
    if (length > avail - hdr) return false;
    if (tag) *tag = t;
    if (val) { val->p = p + hdr; val->len = length; }
    in->p += hdr + length;
    in->len -= hdr + length;
    return true;
}

/* Descend into a constructed TLV: read its first child's span. */
static inline bool lmfi_der_into(lmfi_span node, lmfi_span *child) {
    uint8_t tag;
    lmfi_span v;
    lmfi_span cur = node;
    if (!lmfi_der_next(&cur, &tag, &v)) return false;
    *child = v;
    return true;
}

/*
 * Pull the first X.509 certificate out of a DER PKCS#7 SignedData.
 * Structure:
 *   ContentInfo ::= SEQ { contentType OID, [0] EXPLICIT content }
 *   content = SignedData ::= SEQ { version, digestAlgs SET,
 *                                  encapContentInfo,
 *                                  [0] IMPLICIT certificates OPTIONAL, ... }
 * We walk to the [0] certificates field and return its first SEQUENCE
 * (the leaf certificate) as a span into the original buffer.
 */
static inline bool lmfi_p7b_leaf(const uint8_t *der, size_t der_len,
                                 lmfi_span *leaf_out) {
    lmfi_span top = { der, der_len }, contentInfo;
    uint8_t tag;
    /* outer ContentInfo SEQUENCE */
    { lmfi_span t = top; if (!lmfi_der_next(&t, &tag, &contentInfo) ||
        tag != 0x30) return false; }

    lmfi_span ci = contentInfo, v;
    /* contentType OID */
    if (!lmfi_der_next(&ci, &tag, &v) || tag != 0x06) return false;
    /* [0] EXPLICIT content */
    if (!lmfi_der_next(&ci, &tag, &v) || tag != 0xA0) return false;

    lmfi_span signedDataWrap = v, signedData;
    if (!lmfi_der_next(&signedDataWrap, &tag, &signedData) || tag != 0x30)
        return false;

    /* Walk SignedData children looking for context [0] = certificates. */
    lmfi_span sd = signedData, field;
    while (lmfi_der_next(&sd, &tag, &field)) {
        if (tag == 0xA0) {
            /* certificates: SET-like; first child SEQUENCE is the leaf cert. */
            lmfi_span certs = field, cert;
            if (!lmfi_der_next(&certs, &tag, &cert) || tag != 0x30)
                return false;
            /* leaf span = the whole cert TLV, re-read from field start */
            lmfi_span again = field;
            size_t before = again.len;
            const uint8_t *start = again.p;
            if (!lmfi_der_next(&again, &tag, &cert)) return false;
            size_t consumed = before - again.len;
            leaf_out->p = start;
            leaf_out->len = consumed;   /* full TLV incl. header */
            return true;
        }
    }
    return false;
}

/* Return the Nth (0-based) child TLV value of a constructed node. */
static inline bool lmfi_der_child(lmfi_span node, int index,
                                  uint8_t *tag, lmfi_span *val) {
    lmfi_span cur = node;
    for (int i = 0; ; i++) {
        uint8_t t;
        lmfi_span v;
        if (!lmfi_der_next(&cur, &t, &v)) return false;
        if (i == index) { if (tag) *tag = t; *val = v; return true; }
    }
}

/*
 * Extract the 32-byte private scalar from a DER PKCS#8 EC private key.
 *   PrivateKeyInfo ::= SEQ { version INT, algId SEQ, privateKey OCTETSTRING }
 *   privateKey content = ECPrivateKey ::= SEQ { version INT(1),
 *                                               privateKey OCTETSTRING(32), ...}
 */
static inline bool lmfi_pk8_scalar(const uint8_t *der, size_t der_len,
                                   uint8_t out32[32]) {
    lmfi_span top = { der, der_len }, pki;
    uint8_t tag;
    if (!lmfi_der_next(&top, &tag, &pki) || tag != 0x30) return false;
    /* child 2 = privateKey OCTET STRING holding the ECPrivateKey */
    lmfi_span ecpk_wrap;
    if (!lmfi_der_child(pki, 2, &tag, &ecpk_wrap) || tag != 0x04) return false;
    lmfi_span ecpk_iter = ecpk_wrap, ecpk;
    if (!lmfi_der_next(&ecpk_iter, &tag, &ecpk) || tag != 0x30) return false;
    /* child 1 = privateKey OCTET STRING (the scalar) */
    lmfi_span scalar;
    if (!lmfi_der_child(ecpk, 1, &tag, &scalar) || tag != 0x04) return false;
    if (scalar.len == 32) {
        memcpy(out32, scalar.p, 32);
        return true;
    }
    /* tolerate a leading zero pad or short scalar: right-align into 32 bytes */
    if (scalar.len == 33 && scalar.p[0] == 0x00) {
        memcpy(out32, scalar.p + 1, 32);
        return true;
    }
    if (scalar.len < 32) {
        memset(out32, 0, 32);
        memcpy(out32 + (32 - scalar.len), scalar.p, scalar.len);
        return true;
    }
    return false;
}

/*
 * Extract the uncompressed EC point (0x04 || X || Y, 65 bytes) from a DER
 * X.509 certificate's SubjectPublicKeyInfo.
 *   Certificate ::= SEQ { tbsCertificate SEQ, sigAlg, sig }
 *   tbs children (with explicit [0] version): [0]ver, serial, sigAlg, issuer,
 *       validity, subject, subjectPublicKeyInfo, ...
 *   SPKI ::= SEQ { algId SEQ, subjectPublicKey BIT STRING }
 *   BIT STRING content = 0x00 (unused bits) || 0x04 X Y
 */
static inline bool lmfi_cert_ec_point(const uint8_t *der, size_t der_len,
                                      uint8_t out_point[65]) {
    lmfi_span top = { der, der_len }, cert, tbs;
    uint8_t tag;
    if (!lmfi_der_next(&top, &tag, &cert) || tag != 0x30) return false;
    if (!lmfi_der_child(cert, 0, &tag, &tbs) || tag != 0x30) return false;

    /* Scan tbs children for the SPKI: the SEQUENCE whose last child is a
     * BIT STRING. Index varies with the optional explicit [0] version, so
     * detect it structurally instead of by position. */
    lmfi_span cur = tbs;
    for (;;) {
        lmfi_span field;
        if (!lmfi_der_next(&cur, &tag, &field)) return false;
        if (tag != 0x30) continue;             /* SPKI is a SEQUENCE */
        /* second child must be a BIT STRING for this to be the SPKI */
        lmfi_span bits;
        uint8_t bt;
        if (!lmfi_der_child(field, 1, &bt, &bits) || bt != 0x03) continue;
        if (bits.len != 66 || bits.p[0] != 0x00 || bits.p[1] != 0x04)
            continue;                          /* want 0x00 pad + 65-byte point */
        memcpy(out_point, bits.p + 1, 65);
        return true;
    }
}

/* DER ECDSA-Sig-Value { r INTEGER, s INTEGER } -> raw r||s (32+32 bytes). */
static inline bool lmfi_der_sig_to_raw(const uint8_t *der, size_t der_len,
                                       uint8_t out[64]) {
    lmfi_span top = { der, der_len }, seq;
    uint8_t tag;
    if (!lmfi_der_next(&top, &tag, &seq) || tag != 0x30) return false;
    lmfi_span cur = seq, r, s;
    if (!lmfi_der_next(&cur, &tag, &r) || tag != 0x02) return false;
    if (!lmfi_der_next(&cur, &tag, &s) || tag != 0x02) return false;

    memset(out, 0, 64);
    const uint8_t *rp = r.p; size_t rl = r.len;
    const uint8_t *sp = s.p; size_t sl = s.len;
    while (rl > 0 && *rp == 0x00) { rp++; rl--; }   /* strip sign byte / pad */
    while (sl > 0 && *sp == 0x00) { sp++; sl--; }
    if (rl > 32 || sl > 32) return false;
    memcpy(out + (32 - rl), rp, rl);
    memcpy(out + 32 + (32 - sl), sp, sl);
    return true;
}

/* Read a whole file (<= LOCAL_MFI_MAX_FILE) into a malloc'd buffer. */
static inline uint8_t *lmfi_read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long size = ftell(f);
    if (size <= 0 || size > (long)LOCAL_MFI_MAX_FILE) { fclose(f); return NULL; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    uint8_t *buf = (uint8_t *)malloc((size_t)size);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, (size_t)size, f);
    fclose(f);
    if (got != (size_t)size) { free(buf); return NULL; }
    *out_len = (size_t)size;
    return buf;
}

/* Find the directory holding both files; write full paths; return true. */
static inline bool lmfi_locate(char *cert_path, char *key_path, size_t cap) {
    size_t n = sizeof(LOCAL_MFI_DIRS) / sizeof(LOCAL_MFI_DIRS[0]);
    for (size_t i = 0; i < n; i++) {
        char c[1024], k[1024];
        snprintf(c, sizeof(c), "%s/%s", jb_fix(LOCAL_MFI_DIRS[i]), LOCAL_MFI_CERT_NAME);
        snprintf(k, sizeof(k), "%s/%s", jb_fix(LOCAL_MFI_DIRS[i]), LOCAL_MFI_KEY_NAME);
        FILE *cf = fopen(c, "rb");
        if (!cf) continue;
        fclose(cf);
        FILE *kf = fopen(k, "rb");
        if (!kf) continue;
        fclose(kf);
        snprintf(cert_path, cap, "%s", c);
        snprintf(key_path, cap, "%s", k);
        return true;
    }
    return false;
}

#endif /* SHOWCASE_LOCAL_MFI_H */
