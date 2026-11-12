#import <Foundation/Foundation.h>

// 公共头仅依赖系统类型，兼容 CocoaPods 符号链接和 framework 复制布局。
#include <stdint.h>
#include <stddef.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ZDStringProtectionErrorDomain;

// 初始化时 Runtime 会复制 Blob 和 key，调用方返回后即可释放输入对象。
FOUNDATION_EXPORT BOOL ZDStringProtectionInitialize(NSData *blob, NSData *key, NSError **error);

// 从最终 Mach-O 的 __DATA,__zdstring section 初始化，调用方只需提供 32 字节 Runtime key。
FOUNDATION_EXPORT BOOL ZDStringProtectionInitializeEmbedded(NSData *key, NSError **error);

// Swift 直接使用这个无 Foundation 的 bootstrap ABI，返回值与 Rust Runtime 错误码一致。
FOUNDATION_EXPORT uint32_t zd_string_runtime_init_embedded(const uint8_t *key, size_t key_length);

// M1/M2 仅提供 ID 访问，源码字面量 API 留到源码扫描阶段。
FOUNDATION_EXPORT NSString * _Nullable ZDStringID(uint64_t stringID);

NS_ASSUME_NONNULL_END
