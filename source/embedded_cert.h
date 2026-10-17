/*
 * embedded_cert.h — placeholder.
 *
 * This checked-in version has NO certificate (EMB_CERT_PRESENT 0), so the
 * source tree is safe to publish: it contains no private key.
 *
 * To bake a certificate into the binary (option 1 — obfuscated, for shipped
 * builds), regenerate this file locally right before compiling and do NOT
 * commit the result:
 *
 *     python3 tools/gen_embedded_cert.py \
 *         certificate.p7b identity.pk8 > source/embedded_cert.h
 *
 * When EMB_CERT_PRESENT is 0 the embedded loader is a no-op and Showcase falls
 * back to loose files in /var/jb/etc/showcase, then to online BAA.
 */
#ifndef SHOWCASE_EMBEDDED_CERT_H
#define SHOWCASE_EMBEDDED_CERT_H
#define EMB_CERT_PRESENT 0
#endif /* SHOWCASE_EMBEDDED_CERT_H */
