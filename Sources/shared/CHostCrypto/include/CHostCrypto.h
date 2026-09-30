#ifndef SWIFTLIGHT_HOST_CRYPTO_H
#define SWIFTLIGHT_HOST_CRYPTO_H
#include <stddef.h>
#include <stdint.h>
typedef struct { uint8_t *bytes; size_t length; } SLHostBytes;
typedef struct { SLHostBytes certificate_pem, private_key_pem, pkcs12; } SLHostIdentity;
int sl_host_identity_create(const char *password, SLHostIdentity *result);
void sl_host_bytes_free(SLHostBytes *bytes);
void sl_host_identity_free(SLHostIdentity *identity);
int sl_host_certificate_der(const uint8_t *pem, size_t length, SLHostBytes *result);
int sl_host_certificate_signature(const uint8_t *pem, size_t length, SLHostBytes *result);
int sl_host_sign(const uint8_t *key, size_t key_length, const uint8_t *message, size_t length, SLHostBytes *result);
int sl_host_verify(const uint8_t *pem, size_t pem_length, const uint8_t *message, size_t length, const uint8_t *signature, size_t signature_length);
int sl_host_aes_ecb(const uint8_t *key, const uint8_t *input, size_t length, int encrypt, SLHostBytes *result);
#endif
