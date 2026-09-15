#include "CHostCrypto.h"
#include <limits.h>
#include <string.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>

static int copy_bytes(const void *bytes, size_t length, SLHostBytes *out) {
    if (!bytes || !length || !out) return 0;
    out->bytes = OPENSSL_malloc(length);
    if (!out->bytes) return 0;
    memcpy(out->bytes, bytes, length); out->length = length; return 1;
}
static int copy_bio(BIO *bio, SLHostBytes *out) {
    char *ptr = NULL; long length = BIO_get_mem_data(bio, &ptr);
    return length > 0 && copy_bytes(ptr, (size_t)length, out);
}
void sl_host_bytes_free(SLHostBytes *bytes) {
    if (!bytes) return;
    OPENSSL_clear_free(bytes->bytes, bytes->length); bytes->bytes = NULL; bytes->length = 0;
}
void sl_host_identity_free(SLHostIdentity *identity) {
    if (!identity) return;
    sl_host_bytes_free(&identity->certificate_pem);
    sl_host_bytes_free(&identity->private_key_pem);
    sl_host_bytes_free(&identity->pkcs12);
}
int sl_host_identity_create(const char *password, SLHostIdentity *out) {
    int ok = 0; EVP_PKEY *key = NULL; X509 *cert = NULL; PKCS12 *p12 = NULL;
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, NULL);
    BIO *cert_bio = NULL, *key_bio = NULL, *p12_bio = NULL;
    unsigned char serial[16]; BIGNUM *serial_bn = NULL;
    if (!out) goto done;
    memset(out, 0, sizeof(*out));
    if (!password) goto done;
    if (!ctx || EVP_PKEY_keygen_init(ctx) <= 0 || EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, 2048) <= 0 || EVP_PKEY_keygen(ctx, &key) <= 0) goto done;
    cert = X509_new();
    if (!cert || RAND_bytes(serial, sizeof(serial)) != 1) goto done;
    serial[0] &= 0x7f;
    serial_bn = BN_bin2bn(serial, sizeof(serial), NULL);
    if (!serial_bn || !BN_to_ASN1_INTEGER(serial_bn, X509_get_serialNumber(cert)) || !X509_set_version(cert, 2) ||
        !X509_gmtime_adj(X509_getm_notBefore(cert), -60) || !X509_gmtime_adj(X509_getm_notAfter(cert), 60L*60*24*365*20) || !X509_set_pubkey(cert, key)) goto done;
    X509_NAME *name = X509_get_subject_name(cert);
    if (!X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const unsigned char *)"Swiftlight GameStream Client", -1, -1, 0) ||
        !X509_set_issuer_name(cert, name) || !X509_sign(cert, key, EVP_sha256())) goto done;
    // Apple's PKCS#12 importer requires legacy-compatible key encryption and SHA-1 MAC.
    // This is only an in-memory transport envelope; the persistent envelope lives in Keychain.
    p12 = PKCS12_create(password, "Swiftlight", key, cert, NULL, NID_pbe_WithSHA1And3_Key_TripleDES_CBC, -1, 2048, -1, 0);
    if (!p12 || !PKCS12_set_mac(p12, password, -1, NULL, 0, 1, EVP_sha1())) goto done;
    cert_bio = BIO_new(BIO_s_mem()); key_bio = BIO_new(BIO_s_mem()); p12_bio = BIO_new(BIO_s_mem());
    if (!cert_bio || !key_bio || !p12_bio || !PEM_write_bio_X509(cert_bio, cert) || !PEM_write_bio_PrivateKey(key_bio, key, NULL, NULL, 0, NULL, NULL) ||
        !i2d_PKCS12_bio(p12_bio, p12) || !copy_bio(cert_bio, &out->certificate_pem) || !copy_bio(key_bio, &out->private_key_pem) || !copy_bio(p12_bio, &out->pkcs12)) goto done;
    ok = 1;
done:
    if (!ok && out) sl_host_identity_free(out);
    if (key_bio) { char *bytes = NULL; long length = BIO_get_mem_data(key_bio, &bytes); if (length > 0) OPENSSL_cleanse(bytes, (size_t)length); }
    BIO_free(cert_bio); BIO_free(key_bio); BIO_free(p12_bio); PKCS12_free(p12); X509_free(cert); EVP_PKEY_free(key); EVP_PKEY_CTX_free(ctx); BN_free(serial_bn);
    return ok;
}
static X509 *read_cert(const uint8_t *pem, size_t length) {
    if (!pem || length > INT_MAX) return NULL;
    BIO *bio = BIO_new_mem_buf(pem, (int)length);
    if (!bio) return NULL;
    X509 *cert = PEM_read_bio_X509(bio, NULL, NULL, NULL); BIO_free(bio); return cert;
}
int sl_host_certificate_der(const uint8_t *pem, size_t length, SLHostBytes *out) {
    X509 *cert = read_cert(pem, length); if (!cert) return 0;
    BIO *bio = BIO_new(BIO_s_mem());
    int ok = bio && i2d_X509_bio(bio, cert) && copy_bio(bio, out);
    BIO_free(bio); X509_free(cert); return ok;
}
int sl_host_certificate_signature(const uint8_t *pem, size_t length, SLHostBytes *out) {
    X509 *cert = read_cert(pem, length); if (!cert) return 0;
    const ASN1_BIT_STRING *signature = NULL; X509_get0_signature(&signature, NULL, cert);
    int ok = signature && copy_bytes(ASN1_STRING_get0_data(signature), (size_t)ASN1_STRING_length(signature), out);
    X509_free(cert); return ok;
}
int sl_host_sign(const uint8_t *key_pem, size_t key_length, const uint8_t *message, size_t length, SLHostBytes *out) {
    if (!key_pem || key_length > INT_MAX || !out) return 0;
    BIO *bio = BIO_new_mem_buf(key_pem, (int)key_length); if (!bio) return 0;
    EVP_PKEY *key = PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL); BIO_free(bio);
    EVP_MD_CTX *ctx = EVP_MD_CTX_new(); int ok = 0; size_t count = 0;
    if (!key || !ctx || EVP_DigestSignInit(ctx, NULL, EVP_sha256(), NULL, key) <= 0 || EVP_DigestSignUpdate(ctx, message, length) <= 0 || EVP_DigestSignFinal(ctx, NULL, &count) <= 0) goto done;
    out->bytes = OPENSSL_malloc(count); out->length = count;
    if (!out->bytes || EVP_DigestSignFinal(ctx, out->bytes, &out->length) <= 0) goto done;
    ok = 1;
done:
    if (!ok) sl_host_bytes_free(out); EVP_MD_CTX_free(ctx); EVP_PKEY_free(key); return ok;
}
int sl_host_verify(const uint8_t *pem, size_t pem_length, const uint8_t *message, size_t length, const uint8_t *signature, size_t signature_length) {
    X509 *cert = read_cert(pem, pem_length); if (!cert) return 0;
    EVP_PKEY *key = X509_get_pubkey(cert); EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    int ok = key && ctx && EVP_DigestVerifyInit(ctx, NULL, EVP_sha256(), NULL, key) > 0 && EVP_DigestVerifyUpdate(ctx, message, length) > 0 && EVP_DigestVerifyFinal(ctx, signature, signature_length) == 1;
    EVP_MD_CTX_free(ctx); EVP_PKEY_free(key); X509_free(cert); return ok;
}
int sl_host_aes_ecb(const uint8_t *key, const uint8_t *input, size_t length, int encrypt, SLHostBytes *out) {
    if (!key || !input || !out || !length || length % 16 || length > INT_MAX - 16) return 0;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new(); int actual = 0, final = 0, ok = 0;
    if (!ctx || EVP_CipherInit_ex(ctx, EVP_aes_128_ecb(), NULL, key, NULL, encrypt) <= 0 || EVP_CIPHER_CTX_set_padding(ctx, 0) <= 0) goto done;
    out->bytes = OPENSSL_malloc(length + 16); out->length = length + 16;
    if (!out->bytes || EVP_CipherUpdate(ctx, out->bytes, &actual, input, (int)length) <= 0 || EVP_CipherFinal_ex(ctx, out->bytes + actual, &final) <= 0 || (size_t)(actual + final) != length) goto done;
    out->length = length; ok = 1;
done:
    if (!ok) sl_host_bytes_free(out); EVP_CIPHER_CTX_free(ctx); return ok;
}
