#include "CHostCrypto.h"
#include <openssl/err.h>
#include <openssl/pkcs12.h>
#include <openssl/provider.h>
#include <openssl/store.h>
#include <openssl/rand.h>
#include <stdio.h>
#include <string.h>

// NIST SP 800-38A F.2.1, first AES-128-CBC block. Disable padding as common-c
// does when verifying raw cipher output; encryption framing remains its owner.
static int cbc_vector(void) {
    const unsigned char key[16] = {0x2b,0x7e,0x15,0x16,0x28,0xae,0xd2,0xa6,0xab,0xf7,0x15,0x88,0x09,0xcf,0x4f,0x3c};
    const unsigned char iv[16] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15};
    const unsigned char input[16] = {0x6b,0xc1,0xbe,0xe2,0x2e,0x40,0x9f,0x96,0xe9,0x3d,0x7e,0x11,0x73,0x93,0x17,0x2a};
    const unsigned char expected[16] = {0x76,0x49,0xab,0xac,0x81,0x19,0xb2,0x46,0xce,0xe9,0x8e,0x9b,0x12,0xe9,0x19,0x7d};
    unsigned char output[32], restored[32]; int count = 0, final = 0;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    int ok = ctx && EVP_EncryptInit_ex(ctx, EVP_aes_128_cbc(), NULL, key, iv) == 1 &&
        EVP_CIPHER_CTX_set_padding(ctx, 0) == 1 &&
        EVP_EncryptUpdate(ctx, output, &count, input, sizeof(input)) == 1 &&
        EVP_EncryptFinal_ex(ctx, output + count, &final) == 1 && count + final == sizeof(expected) &&
        memcmp(output, expected, sizeof(expected)) == 0;
    if (ok) {
        ok = EVP_DecryptInit_ex(ctx, EVP_aes_128_cbc(), NULL, key, iv) == 1 &&
            EVP_CIPHER_CTX_set_padding(ctx, 0) == 1 &&
            EVP_DecryptUpdate(ctx, restored, &count, output, sizeof(expected)) == 1 &&
            EVP_DecryptFinal_ex(ctx, restored + count, &final) == 1 && count + final == sizeof(input) &&
            memcmp(restored, input, sizeof(input)) == 0;
    }
    EVP_CIPHER_CTX_free(ctx);
    return ok;
}

// NIST AES-GCM zero-key/96-bit-IV/one-zero-block example. Verify both encryption
// and authenticated decryption, including rejection of a changed tag.
static int gcm_vector(void) {
    const unsigned char key[16] = {0}, iv[12] = {0}, input[16] = {0};
    const unsigned char expected[16] = {0x03,0x88,0xda,0xce,0x60,0xb6,0xa3,0x92,0xf3,0x28,0xc2,0xb9,0x71,0xb2,0xfe,0x78};
    const unsigned char expected_tag[16] = {0xab,0x6e,0x47,0xd4,0x2c,0xec,0x13,0xbd,0xf5,0x3a,0x67,0xb2,0x12,0x57,0xbd,0xdf};
    unsigned char output[32], tag[16], restored[32]; int count = 0, final = 0;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    int ok = ctx && EVP_EncryptInit_ex(ctx, EVP_aes_128_gcm(), NULL, NULL, NULL) == 1 &&
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, sizeof(iv), NULL) == 1 &&
        EVP_EncryptInit_ex(ctx, NULL, NULL, key, iv) == 1 &&
        EVP_EncryptUpdate(ctx, output, &count, input, sizeof(input)) == 1 &&
        EVP_EncryptFinal_ex(ctx, output + count, &final) == 1 && count + final == sizeof(expected) &&
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, sizeof(tag), tag) == 1 &&
        memcmp(output, expected, sizeof(expected)) == 0 && memcmp(tag, expected_tag, sizeof(tag)) == 0;
    for (int tampered = 0; ok && tampered < 2; ++tampered) {
        if (tampered) tag[0] ^= 1;
        ok = EVP_DecryptInit_ex(ctx, EVP_aes_128_gcm(), NULL, NULL, NULL) == 1 &&
            EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, sizeof(iv), NULL) == 1 &&
            EVP_DecryptInit_ex(ctx, NULL, NULL, key, iv) == 1 &&
            EVP_DecryptUpdate(ctx, restored, &count, output, sizeof(expected)) == 1 &&
            EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, sizeof(tag), tag) == 1;
        if (ok) {
            int accepted = EVP_DecryptFinal_ex(ctx, restored + count, &final);
            ok = tampered ? accepted <= 0 : accepted == 1 && count + final == sizeof(input) &&
                memcmp(restored, input, sizeof(input)) == 0;
        }
    }
    EVP_CIPHER_CTX_free(ctx);
    return ok;
}

#ifdef SWIFTLIGHT_EXPECT_NO_FILE_STORE
static int file_store_removed(void) {
    // Check both built-in registrations after default-provider crypto succeeded.
    // Fetching a loader never opens a path or reads Keychain credentials.
    OSSL_PROVIDER *base = OSSL_PROVIDER_load(NULL, "base");
    OSSL_STORE_LOADER *loader = OSSL_STORE_LOADER_fetch(NULL, "file", NULL);
    int ok = base != NULL && loader == NULL;
    OSSL_STORE_LOADER_free(loader); OSSL_PROVIDER_unload(base); ERR_clear_error();
    return ok;
}
#endif

// Ephemeral identity only: never read or replace the app's Keychain credentials.
int main(void) {
    SLHostIdentity identity = {0};
    SLHostBytes der = {0}, certificate_signature = {0}, signature = {0}, ciphertext = {0}, plaintext = {0};
    unsigned char random[32] = {0};
    unsigned char message[] = "Swiftlight mobile pairing probe";
    const unsigned char key[16] = {
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f
    };
    const unsigned char input[16] = {
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
    };
    const unsigned char expected[16] = {
        0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30,
        0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a
    };
    PKCS12 *envelope = NULL;
    int ok = RAND_bytes(random, sizeof(random)) == 1 &&
        sl_host_identity_create("ephemeral-probe-password", &identity) &&
        sl_host_certificate_der(identity.certificate_pem.bytes, identity.certificate_pem.length, &der) &&
        sl_host_certificate_signature(identity.certificate_pem.bytes, identity.certificate_pem.length, &certificate_signature) &&
        sl_host_sign(identity.private_key_pem.bytes, identity.private_key_pem.length, message, sizeof(message), &signature) &&
        sl_host_verify(identity.certificate_pem.bytes, identity.certificate_pem.length, message, sizeof(message), signature.bytes, signature.length);
    if (ok) {
        message[0] ^= 1;
        ok = !sl_host_verify(identity.certificate_pem.bytes, identity.certificate_pem.length, message, sizeof(message), signature.bytes, signature.length);
    }
    if (ok) {
        const unsigned char *bytes = identity.pkcs12.bytes;
        envelope = d2i_PKCS12(NULL, &bytes, (long)identity.pkcs12.length);
        ok = envelope && PKCS12_verify_mac(envelope, "ephemeral-probe-password", -1) == 1 &&
            PKCS12_verify_mac(envelope, "wrong-password", -1) == 0;
    }
    if (ok) {
        ok = sl_host_aes_ecb(key, input, sizeof(input), 1, &ciphertext) && ciphertext.length == sizeof(expected) &&
            memcmp(ciphertext.bytes, expected, sizeof(expected)) == 0 &&
            sl_host_aes_ecb(key, ciphertext.bytes, ciphertext.length, 0, &plaintext) &&
            plaintext.length == sizeof(input) && memcmp(plaintext.bytes, input, sizeof(input)) == 0;
    }
    if (ok) ok = cbc_vector() && gcm_vector();
#ifdef SWIFTLIGHT_EXPECT_NO_FILE_STORE
    if (ok) ok = file_store_removed();
#endif
    PKCS12_free(envelope);
    sl_host_bytes_free(&der); sl_host_bytes_free(&certificate_signature); sl_host_bytes_free(&signature);
    sl_host_bytes_free(&ciphertext); sl_host_bytes_free(&plaintext); sl_host_identity_free(&identity);
    puts(ok ? "{\"status\":\"PASS\",\"secure_entropy\":true,\"identity_pkcs12\":true,\"sign_verify_tamper\":true,\"aes_known_vector\":true,\"transport_cbc_gcm_vectors\":true"
#ifdef SWIFTLIGHT_EXPECT_NO_FILE_STORE
            ",\"file_store_unavailable\":true"
#endif
            "}"
            : "{\"status\":\"FAIL\",\"mobile_pairing_crypto\":false}");
    return ok ? 0 : 1;
}
