import Foundation
import ZDObfKit

// 1. 在访问任何受保护字符串之前初始化一次。
//    构建时 ZD_STRING_EMBED_KEY=1，key 已随密文内嵌，所以这里不需要传 key（key 只在构建脚本里配置一处）。
//    真实 App 若要把 key 与密文分离，改用 ZDObf.initializeEmbedded(key:) 并从 Keychain/服务端取得 key。
do {
    try ZDObf.initializeEmbedded()
} catch {
    print("ZDObf initialization failed: \(error)")
    exit(1)
}

// 2. 之后可以像普通字符串一样使用；明文只在运行时出现在内存里。
print("user url : \(ProtectedAPI.userURL ?? "<unavailable>")")
print("greeting : \(ProtectedAPI.greeting ?? "<unavailable>")")
print("objc host: \(DemoProtectedAnalyticsHost() ?? "<unavailable>")")

// 3. 需要明确错误时，用抛错的查询 API；这里故意查询一个不存在的 ID。
do {
    _ = try ZDObf.string(for: 0xdead_beef)
} catch ZDObfError.invalidID {
    print("unknown id is reported as invalidID")
} catch {
    print("unexpected error: \(error)")
}
