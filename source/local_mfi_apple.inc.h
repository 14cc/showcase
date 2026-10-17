/*
 * local_mfi_apple.inc.h — Apple Security-framework glue for local_mfi.h.
 *
 * #include "local_mfi_apple.inc.h" from an Objective-C translation unit that
 * already includes <Security/Security.h>, <CommonCrypto/CommonCrypto.h> and
 * "local_mfi.h". Provides:
 *
 *   bool  local_mfi_load(uint8_t **p7b, int *p7b_len, SecKeyRef *key)
 *       Locate certificate.p7b + identity.pk8, hand back the raw p7b bytes
 *       (sent to the phone verbatim) and a SecKeyRef P-256 private key
 *       assembled from the pk8 scalar + the cert's public point.
 *
 *   bool  local_mfi_sign_raw(SecKeyRef key, const uint8_t *digest32,
 *                            uint8_t out_sig[64])
 *       ECDSA-sign a 32-byte digest (DigestX962/SHA256 — the input IS the
 *       digest, no extra hashing) and return the signature as raw r||s.
 *
 * iOS has no public PKCS#8 importer, so we rebuild the ANSI X9.63 key blob
 * (0x04||X||Y||scalar) that SecKeyCreateWithData accepts.
 */

#ifndef SHOWCASE_LOCAL_MFI_APPLE_INC_H
#define SHOWCASE_LOCAL_MFI_APPLE_INC_H

#include "embedded_cert.h"   /* EMB_CERT_PRESENT + arrays, auto-generated */

/*
 * Build a SecKey from a p7b (public cert) + 32-byte private scalar. iOS has no
 * PKCS#8 importer, so we rebuild the ANSI X9.63 blob (0x04||X||Y||scalar) that
 * SecKeyCreateWithData accepts, then self-check it against the cert's pubkey.
 * The scalar buffer is wiped before returning. Shared by the file and embedded
 * loaders.
 */
static bool local_mfi_build_key(const uint8_t *p7b, size_t p7b_len,
                                uint8_t scalar[32], SecKeyRef *key_out) {
    *key_out = NULL;
    lmfi_span leaf;
    uint8_t point[65];
    if (!lmfi_p7b_leaf(p7b, p7b_len, &leaf) ||
        !lmfi_cert_ec_point(leaf.p, leaf.len, point)) {
        printf("[LMFI] Could not parse certificate (p7b)\n");
        memset(scalar, 0, 32);
        return false;
    }

    uint8_t x963[97];
    memcpy(x963, point, 65);          /* 0x04 || X || Y */
    memcpy(x963 + 65, scalar, 32);    /* private scalar */
    memset(scalar, 0, 32);

    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attrs, kSecAttrKeyType,
                         kSecAttrKeyTypeECSECPrimeRandom);
    CFDictionarySetValue(attrs, kSecAttrKeyClass, kSecAttrKeyClassPrivate);
    int bits = 256;
    CFNumberRef bitsRef = CFNumberCreate(NULL, kCFNumberIntType, &bits);
    CFDictionarySetValue(attrs, kSecAttrKeySizeInBits, bitsRef);

    CFDataRef keyData = CFDataCreate(NULL, x963, sizeof(x963));
    CFErrorRef error = NULL;
    SecKeyRef key = SecKeyCreateWithData(keyData, attrs, &error);

    memset(x963 + 65, 0, 32);
    CFRelease(keyData);
    CFRelease(bitsRef);
    CFRelease(attrs);

    if (!key) {
        printf("[LMFI] SecKeyCreateWithData failed\n");
        if (error) { NSLog(@"[LMFI] %@", error); CFRelease(error); }
        return false;
    }

    /* Sanity: private key must match the cert's public key. */
    SecKeyRef pub = SecKeyCopyPublicKey(key);
    if (pub) {
        static const uint8_t probe[32] = {
            1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,
            17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32 };
        CFDataRef probeData = CFDataCreate(NULL, probe, sizeof(probe));
        CFErrorRef e2 = NULL;
        CFDataRef sig = SecKeyCreateSignature(
            key, kSecKeyAlgorithmECDSASignatureDigestX962SHA256,
            probeData, &e2);
        bool matches = false;
        if (sig) {
            matches = SecKeyVerifySignature(
                pub, kSecKeyAlgorithmECDSASignatureDigestX962SHA256,
                probeData, sig, NULL);
            CFRelease(sig);
        }
        if (e2) CFRelease(e2);
        CFRelease(probeData);
        CFRelease(pub);
        if (!matches) {
            printf("[LMFI] private key does not match certificate public key\n");
            CFRelease(key);
            return false;
        }
    }

    *key_out = key;
    return true;
}

/* Source 1: loose files in /var/jb/etc/showcase (dev override). */
static bool local_mfi_load(uint8_t **p7b_out, int *p7b_len_out,
                            SecKeyRef *key_out) {
    *p7b_out = NULL; *p7b_len_out = 0; *key_out = NULL;

    char cert_path[1024], key_path[1024];
    if (!lmfi_locate(cert_path, key_path, sizeof(cert_path))) return false;

    size_t p7b_len = 0, pk8_len = 0;
    uint8_t *p7b = lmfi_read_file(cert_path, &p7b_len);
    uint8_t *pk8 = lmfi_read_file(key_path, &pk8_len);
    if (!p7b || !pk8) { free(p7b); free(pk8); return false; }

    uint8_t scalar[32];
    bool ok = lmfi_pk8_scalar(pk8, pk8_len, scalar) &&
              local_mfi_build_key(p7b, p7b_len, scalar, key_out);
    free(pk8);
    if (!ok) { free(p7b); return false; }

    *p7b_out = p7b;
    *p7b_len_out = (int)p7b_len;
    printf("[LMFI] Local MFi certificate loaded from files: p7b=%d bytes, key OK\n",
           (int)p7b_len);
    printf("[LMFI]   cert: %s\n[LMFI]   key:  %s\n", cert_path, key_path);
    return true;
}

/* Source 2: certificate baked into the binary (obfuscated scalar). */
static bool local_mfi_load_embedded(uint8_t **p7b_out, int *p7b_len_out,
                                    SecKeyRef *key_out) {
    *p7b_out = NULL; *p7b_len_out = 0; *key_out = NULL;
#if EMB_CERT_PRESENT
    /* Recover the scalar: enc XOR SHA256(salt). */
    uint8_t keystream[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(EMB_SALT, (CC_LONG)sizeof(EMB_SALT), keystream);
    uint8_t scalar[32];
    for (int i = 0; i < 32; i++) scalar[i] = EMB_SCALAR_ENC[i] ^ keystream[i];
    memset(keystream, 0, sizeof(keystream));

    uint8_t *p7b = (uint8_t *)malloc(EMB_P7B_LEN);
    if (!p7b) { memset(scalar, 0, sizeof(scalar)); return false; }
    memcpy(p7b, EMB_P7B, EMB_P7B_LEN);

    if (!local_mfi_build_key(p7b, EMB_P7B_LEN, scalar, key_out)) {
        free(p7b);
        return false;
    }
    *p7b_out = p7b;
    *p7b_len_out = EMB_P7B_LEN;
    printf("[LMFI] Local MFi certificate loaded (embedded): p7b=%d bytes, key OK\n",
           (int)EMB_P7B_LEN);
    return true;
#else
    return false;
#endif
}

static bool local_mfi_sign_raw(SecKeyRef key, const uint8_t *digest32,
                               uint8_t out_sig[64]) {
    if (!key) return false;
    CFDataRef digestData = CFDataCreate(NULL, digest32, 32);
    CFErrorRef error = NULL;
    CFDataRef der = SecKeyCreateSignature(
        key, kSecKeyAlgorithmECDSASignatureDigestX962SHA256,
        digestData, &error);
    CFRelease(digestData);
    if (!der) {
        if (error) { NSLog(@"[LMFI] sign failed: %@", error); CFRelease(error); }
        return false;
    }
    bool ok = lmfi_der_sig_to_raw(CFDataGetBytePtr(der),
                                  (size_t)CFDataGetLength(der), out_sig);
    CFRelease(der);
    return ok;
}

#endif /* SHOWCASE_LOCAL_MFI_APPLE_INC_H */
