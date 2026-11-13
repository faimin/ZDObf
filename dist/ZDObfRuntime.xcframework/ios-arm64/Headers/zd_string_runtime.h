#ifndef ZD_STRING_RUNTIME_H
#define ZD_STRING_RUNTIME_H

#include <stddef.h>
#include <stdint.h>

// C Header 固定 Rust Runtime 的最小 ABI，调用方不得保存 callback 提供的字节指针。

#ifdef __cplusplus
extern "C" {
#endif

enum {
    ZD_STRING_ERROR_OK = 0,
    ZD_STRING_ERROR_INVALID_ARGUMENT = 1,
    ZD_STRING_ERROR_ALREADY_INITIALIZED = 2,
    ZD_STRING_ERROR_NOT_INITIALIZED = 3,
    ZD_STRING_ERROR_INVALID_ID = 4,
    ZD_STRING_ERROR_MALFORMED_BLOB = 5,
    ZD_STRING_ERROR_AUTHENTICATION_FAILED = 6,
    ZD_STRING_ERROR_INVALID_UTF8 = 7,
    ZD_STRING_ERROR_ALLOCATION_FAILED = 8,
    ZD_STRING_ERROR_LIMIT_EXCEEDED = 9,
    ZD_STRING_ERROR_INTERNAL = 100,
};

typedef struct {
    uint8_t *bytes;
    size_t length;
    uint32_t error;
} ZDStringResult;

typedef uint32_t (*ZDStringUseCallback)(const uint8_t *bytes, size_t length, void *context);

uint32_t zd_string_runtime_init(const uint8_t *blob, size_t blob_length, const uint8_t *key, size_t key_length);
uint32_t zd_string_with_utf8(uint64_t string_id, ZDStringUseCallback callback, void *context);
ZDStringResult zd_string_get(uint64_t string_id);
void zd_string_result_free(ZDStringResult *result);

#ifdef __cplusplus
}
#endif

#endif
