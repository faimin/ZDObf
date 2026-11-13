import Foundation

// ⚠️ 仅用于 Demo：真实 App 不要把 key 写进源码。
// 应从 Keychain、安全下发的配置或服务端取得，且必须与构建时的 ZD_STRING_RUNTIME_KEY_B64 一致。
// 这里的 key 是 0x00...0x1f，对应 Scripts/zdobf_build_phase.sh 里默认的 Base64 值。
enum DemoKey {
    static let runtimeKey = Data((0..<32).map { UInt8($0) })
}
