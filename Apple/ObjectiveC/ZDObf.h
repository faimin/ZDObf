#import <Foundation/Foundation.h>

// 公共头仅依赖系统类型，兼容 CocoaPods 符号链接和 framework 复制布局。
#include <stdint.h>
#include <stddef.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ZDObfErrorDomain;

// 初始化时 Runtime 会复制 Blob 和 key，调用方返回后即可释放输入对象。
FOUNDATION_EXPORT BOOL ZDObfInitialize(NSData *blob, NSData *key, NSError **error);

// 从最终 Mach-O 的 __DATA,__zdstring section 初始化，调用方只需提供 32 字节 Runtime key。
FOUNDATION_EXPORT BOOL ZDObfInitializeEmbedded(NSData *key, NSError **error);

// 使用构建时内嵌的 key 初始化（需要 ZD_STRING_EMBED_KEY=1 构建）。key 只在构建环境配置一处，
// 但它（掩码后）与密文同在二进制里，只剩混淆强度的保护；需要更强保护请用 ZDObfInitializeEmbedded 传入运行时取得的 key。
FOUNDATION_EXPORT BOOL ZDObfInitializeEmbeddedWithBuiltInKey(NSError **error);

// Swift 直接使用这个无 Foundation 的 bootstrap ABI，返回值与 Rust Runtime 错误码一致。
FOUNDATION_EXPORT uint32_t zd_string_runtime_init_embedded(const uint8_t *key, size_t key_length);

FOUNDATION_EXPORT uint32_t zd_string_runtime_init_embedded_builtin_key(void);

// Build-generated sources call this internal byte-token decoder; business code keeps ZDString(...).
FOUNDATION_EXPORT NSString * _Nullable ZDStringDecodeBytes(const unsigned char *bytes, size_t length);

NS_ASSUME_NONNULL_END
