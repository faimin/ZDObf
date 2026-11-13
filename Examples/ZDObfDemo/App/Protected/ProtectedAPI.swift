import ZDObfKit

// 这个文件不参与编译：构建阶段会把其中的 ZDString("...") 替换成加密目录的 ID，
// 只有生成后的 Generated/ProtectedAPI.swift 才会进入 Compile Sources。
enum ProtectedAPI {
    /// 返回 nil 表示 Runtime 还没初始化，或 key 与构建时不一致。
    static var userURL: String? {
        ZDString("https://api.example.com/v1/user")
    }

    static var greeting: String? {
        // 非 ASCII、转义字符都可以直接写；插值、拼接和 raw/multiline 字符串不支持。
        ZDString("你好，ZDObf!\n— protected at build time")
    }
}
