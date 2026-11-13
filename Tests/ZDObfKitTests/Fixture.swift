// 由 regenerate_fixture.py 生成，请勿手工修改。
import Foundation

enum Fixture {
    static let namespace = "com.example.zdobf.tests"
    /// debug + deterministic 模式生成的 Blob（Base64）。
    static let blobBase64 = "TE1TVAEAAQAAAAAADYTFHK+Xjal3BP6QMSl8vUhoF7q5fxDGSCsyO7tu2BIXAAAAAwAAAFcAAACTAAAAOgEAAGNvbS5leGFtcGxlLnpkb2JmLnRlc3RzajM7uydZyH6TAAAALwAAAAAAAAAiTXR8DRqqvNoAAAAQAAAAAAAAANpQjSpPhJ/cAgEAACAAAAAAAAAA1ITLYgWZdkAF7FQDec0VHgbhQT6KEbx8u6PNxE6oEKTqIWtVhN1Lh+lu9bqlO5LHaeZQpDrkdauKBjgrEDtGpmwbGip6Hyom4O5qqXyL2L8paO+5LLfs5h52Yg1EXRj5pwKXAE0dRdFX891iuWTMhOXZCFMihKx70e089EvPa58GJT0ETTdIANdubbV3n6FuPrq8ct2Xl1kLgx5lzDgqZW3KH4WpoSo="
    static var blob: Data { Data(base64Encoded: blobBase64)! }
    /// 构建所用的 32 字节 key：0x00...0x1f。
    static let key = Data((0..<32).map { UInt8($0) })

    static let urlID: UInt64 = 0x7ec85927bb3b336a
    static let urlValue = "https://api.example.com/v1/user"
    static let unicodeID: UInt64 = 0xdc9f844f2a8d50da
    static let unicodeValue = "你好，ZDObf!\n"
    static let emptyID: UInt64 = 0xbcaa1a0d7c744d22
    static let emptyValue = ""
}
