import Foundation
import ZDObfKit

// 1. 在访问任何受保护字符串之前初始化一次。
//    initializeEmbedded 会从最终可执行文件的 __DATA,__zdstring section 读取密文 Blob。
do {
    try ZDObf.initializeEmbedded(key: DemoKey.runtimeKey)
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
