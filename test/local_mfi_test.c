/* Linux host test for local_mfi.h DER parsing + signature conversion.
 * Uses OpenSSL only as an independent oracle (the device uses Security.fwk). */
#include "../source/local_mfi.h"
#include <openssl/ec.h>
#include <openssl/ecdsa.h>
#include <openssl/obj_mac.h>
#include <openssl/bn.h>
#include <openssl/sha.h>
#include <openssl/evp.h>
#include <assert.h>

int main(int argc, char **argv) {
    size_t cl, kl;
    uint8_t *p7b = lmfi_read_file(argv[1], &cl);
    uint8_t *pk8 = lmfi_read_file(argv[2], &kl);
    assert(p7b && pk8);

    lmfi_span leaf;
    assert(lmfi_p7b_leaf(p7b, cl, &leaf));
    uint8_t point[65], scalar[32];
    assert(lmfi_cert_ec_point(leaf.p, leaf.len, point));
    assert(point[0] == 0x04);
    assert(lmfi_pk8_scalar(pk8, kl, scalar));
    printf("parse OK: leaf=%zu point04 scalar32\n", leaf.len);

    /* Build EC key from scalar, confirm its public point == cert point. */
    EC_KEY *key = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1);
    BIGNUM *d = BN_bin2bn(scalar, 32, NULL);
    assert(EC_KEY_set_private_key(key, d));
    const EC_GROUP *g = EC_KEY_get0_group(key);
    EC_POINT *pub = EC_POINT_new(g);
    BN_CTX *ctx = BN_CTX_new();
    assert(EC_POINT_mul(g, pub, d, NULL, NULL, ctx));
    assert(EC_KEY_set_public_key(key, pub));
    uint8_t derived[65];
    assert(EC_POINT_point2oct(g, pub, POINT_CONVERSION_UNCOMPRESSED,
                              derived, 65, ctx) == 65);
    assert(memcmp(derived, point, 65) == 0);
    printf("keypair OK: derived public point matches certificate\n");

    /* Sign SHA256(ourPK||peerPK) the way the device will, emit DER, convert to
     * raw via lmfi_der_sig_to_raw, rebuild DER, verify with the public key. */
    uint8_t ourPK[32], peerPK[32], cat[64], md[32];
    for (int i=0;i<32;i++){ourPK[i]=i;peerPK[i]=0x40+i;}
    memcpy(cat, ourPK, 32); memcpy(cat+32, peerPK, 32);
    SHA256(cat, 64, md);

    ECDSA_SIG *sig = ECDSA_do_sign(md, 32, key);
    assert(sig);
    unsigned char *der = NULL; int derlen = i2d_ECDSA_SIG(sig, &der);
    assert(derlen > 0);

    uint8_t raw[64];
    assert(lmfi_der_sig_to_raw(der, derlen, raw));
    printf("der->raw OK: %d-byte DER -> 64-byte raw\n", derlen);

    /* Rebuild DER from raw (what the verifier reconstructs) and verify. */
    BIGNUM *rr = BN_bin2bn(raw, 32, NULL), *ss = BN_bin2bn(raw+32, 32, NULL);
    ECDSA_SIG *sig2 = ECDSA_SIG_new();
    ECDSA_SIG_set0(sig2, rr, ss);
    assert(ECDSA_do_verify(md, 32, sig2, key) == 1);
    printf("verify OK: raw r||s round-trips and verifies against cert key\n");

    /* Negative: a flipped digest bit must fail. */
    md[0] ^= 1;
    assert(ECDSA_do_verify(md, 32, sig2, key) == 0);
    printf("negative OK: tampered digest rejected\n");

    printf("\nALL LOCAL-MFI TESTS PASSED\n");
    return 0;
}
