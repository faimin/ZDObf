#import "ZDObf.h"

// Rust ABI 仅在实现文件使用，避免公共头依赖源码目录结构。
#import "../../crates/runtime/include/zd_string_runtime.h"

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

uint32_t zd_string_runtime_init_embedded(const uint8_t *key, size_t keyLength) {
    if (key == NULL || keyLength != 32) {
        return ZD_STRING_ERROR_INVALID_ARGUMENT;
    }
    // 密文 section 由最终链接注入主可执行文件；dyld 的 0 号镜像即主可执行文件，
    // 这样 wrapper 位于动态 framework 时也能链接（_mh_execute_header 只存在于可执行文件镜像）。
    // Rust Runtime 仍只接收字节指针。
    const ZDMachHeader *header = (const ZDMachHeader *)_dyld_get_image_header(0);
    if (header == NULL) {
        return ZD_STRING_ERROR_MALFORMED_BLOB;
    }
    unsigned long sectionLength = 0;
    const uint8_t *section = getsectiondata(header, "__DATA", "__zdstring", &sectionLength);
    if (section == NULL || sectionLength == 0) {
        return ZD_STRING_ERROR_MALFORMED_BLOB;
    }
    return zd_string_runtime_init(section, (size_t)sectionLength, key, keyLength);
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
