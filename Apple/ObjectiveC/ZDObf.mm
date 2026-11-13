#import "ZDObf.h"

// Rust ABI 仅在实现文件使用，避免公共头依赖源码目录结构。
#import "../../crates/runtime/include/zd_string_runtime.h"

#include <string.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>

#ifdef __LP64__
typedef struct mach_header_64 ZDMachHeader;
#else
typedef struct mach_header ZDMachHeader;
#endif

NSString *const ZDObfErrorDomain = @"ZDObf";

struct ZDStringCaptureContext {
    NSString * __strong value;
};

static NSError *ZDObfError(uint32_t code) {
    NSString *description = [NSString stringWithFormat:@"ZDObf runtime error (%u)", code];
    return [NSError errorWithDomain:ZDObfErrorDomain code:(NSInteger)code userInfo:@{NSLocalizedDescriptionKey: description}];
}

BOOL ZDObfInitialize(NSData *blob, NSData *key, NSError **error) {
    if (blob.length == 0 || key.length != 32) {
        if (error != NULL) {
            *error = ZDObfError(ZD_STRING_ERROR_INVALID_ARGUMENT);
        }
        return NO;
    }

    uint32_t code = zd_string_runtime_init((const uint8_t *)blob.bytes, blob.length, (const uint8_t *)key.bytes, key.length);
    if (code != ZD_STRING_ERROR_OK) {
        if (error != NULL) {
            *error = ZDObfError(code);
        }
        return NO;
    }
    return YES;
}

BOOL ZDObfInitializeEmbedded(NSData *key, NSError **error) {
    if (key.length != 32) {
        if (error != NULL) {
            *error = ZDObfError(ZD_STRING_ERROR_INVALID_ARGUMENT);
        }
        return NO;
    }

    uint32_t code = zd_string_runtime_init_embedded((const uint8_t *)key.bytes, key.length);
    if (code != ZD_STRING_ERROR_OK) {
        if (error != NULL) {
            *error = ZDObfError(code);
        }
        return NO;
    }
    return YES;
}

// 在 dyld 镜像里查找密文 section（以及可选的内嵌 key section，来自同一个镜像）。
// 通常在主可执行文件（0 号镜像）；Xcode 的 Debug dylib（ENABLE_DEBUG_DYLIB）模式下主可执行文件只是壳，
// section 随业务代码落在 App.debug.dylib 中，因此从 0 号镜像开始按加载顺序找第一个带 __DATA,__zdstring 的镜像。
// 不用 _mh_execute_header：它只存在于可执行文件镜像，wrapper 位于动态 framework 时无法链接。
// 即使别的镜像带有同名 section，没有构建 key 也无法通过认证，最坏只会初始化失败。
static BOOL ZDObfLocateSections(const uint8_t **blob, unsigned long *blobLength,
                                const uint8_t **keyBlob, unsigned long *keyBlobLength) {
    const uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        const ZDMachHeader *header = (const ZDMachHeader *)_dyld_get_image_header(index);
        if (header == NULL) {
            continue;
        }
        unsigned long length = 0;
        const uint8_t *section = getsectiondata(header, "__DATA", "__zdstring", &length);
        if (section != NULL && length != 0) {
            *blob = section;
            *blobLength = length;
            *keyBlob = getsectiondata(header, "__DATA", "__zdkey", keyBlobLength);
            return YES;
        }
    }
    return NO;
}

uint32_t zd_string_runtime_init_embedded(const uint8_t *key, size_t keyLength) {
    if (key == NULL || keyLength != 32) {
        return ZD_STRING_ERROR_INVALID_ARGUMENT;
    }
    const uint8_t *section = NULL, *keySection = NULL;
    unsigned long sectionLength = 0, keySectionLength = 0;
    if (!ZDObfLocateSections(&section, &sectionLength, &keySection, &keySectionLength)) {
        return ZD_STRING_ERROR_MALFORMED_BLOB;
    }
    return zd_string_runtime_init(section, (size_t)sectionLength, key, keyLength);
}

// 内嵌 key 模式（构建时 ZD_STRING_EMBED_KEY=1）：载荷为 "ZDKY" | version u16 | flags u16 | mask[32] | masked[32]，
// key = mask xor masked。这只是避免 key 以明文字节出现的混淆，不是加密。
uint32_t zd_string_runtime_init_embedded_builtin_key(void) {
    const uint8_t *section = NULL, *keySection = NULL;
    unsigned long sectionLength = 0, keySectionLength = 0;
    if (!ZDObfLocateSections(&section, &sectionLength, &keySection, &keySectionLength)) {
        return ZD_STRING_ERROR_MALFORMED_BLOB;
    }
    if (keySection == NULL || keySectionLength != 72 || memcmp(keySection, "ZDKY", 4) != 0 ||
        keySection[4] != 1 || keySection[5] != 0 || keySection[6] != 0 || keySection[7] != 0) {
        return ZD_STRING_ERROR_MALFORMED_BLOB;
    }
    uint8_t key[32];
    for (size_t index = 0; index < sizeof(key); index++) {
        key[index] = keySection[8 + index] ^ keySection[40 + index];
    }
    uint32_t code = zd_string_runtime_init(section, (size_t)sectionLength, key, sizeof(key));
    // volatile 写入避免编译器把对即将离开作用域的 key 的清零优化掉。
    for (volatile uint8_t *cursor = key; cursor < key + sizeof(key); cursor++) {
        *cursor = 0;
    }
    return code;
}

BOOL ZDObfInitializeEmbeddedWithBuiltInKey(NSError **error) {
    uint32_t code = zd_string_runtime_init_embedded_builtin_key();
    if (code != ZD_STRING_ERROR_OK) {
        if (error != NULL) {
            *error = ZDObfError(code);
        }
        return NO;
    }
    return YES;
}

static uint32_t ZDObfCaptureCallback(const uint8_t *bytes, size_t length, void *context) {
    // 回调同步执行，NSString 在返回前复制数据，Rust 随后即可清理明文缓冲区。
    ZDStringCaptureContext *capture = (ZDStringCaptureContext *)context;
    if (bytes == NULL && length != 0) {
        return ZD_STRING_ERROR_INVALID_ARGUMENT;
    }
    NSString *value = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    if (length == 0 && value == nil) {
        value = @"";
    }
    if (value == nil && length != 0) {
        return ZD_STRING_ERROR_INVALID_UTF8;
    }
    capture->value = value;
    return ZD_STRING_ERROR_OK;
}

NSString * _Nullable ZDStringDecodeBytes(const unsigned char *bytes, size_t length) {
    if (bytes == NULL || length != sizeof(uint64_t)) {
        return nil;
    }
    uint64_t stringID = 0;
    for (size_t index = 0; index < length; index++) {
        stringID |= ((uint64_t)bytes[index]) << (index * 8);
    }
    ZDStringCaptureContext capture = { nil };
    uint32_t code = zd_string_with_utf8(stringID, ZDObfCaptureCallback, (void *)&capture);
#if DEBUG
    if (code != ZD_STRING_ERROR_OK) {
        // 未初始化或 key/Blob 不匹配时静默返回 nil 很难排查，仅 Debug 构建输出错误码（不含明文）。
        NSLog(@"[ZDObf] decode failed for string id 0x%llx (error %u); was ZDObfInitializeEmbedded called?", (unsigned long long)stringID, code);
    }
#endif
    return code == ZD_STRING_ERROR_OK ? capture.value : nil;
}
