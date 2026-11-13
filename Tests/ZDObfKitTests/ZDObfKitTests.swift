import XCTest
import ZDObfKit

// Runtime 是进程级单例：初始化成功后无法回退，所以这些用例按名字顺序依赖彼此，
// 编号前缀保证“未初始化 → 失败的初始化 → 成功初始化”的执行顺序。
final class ZDObfKitTests: XCTestCase {
    func test01_QueryBeforeInitializationFails() {
        XCTAssertThrowsError(try ZDObf.string(for: Fixture.urlID)) { error in
            XCTAssertEqual(error as? ZDObfError, .notInitialized)
        }
        // 便捷解码入口不抛错，未初始化时返回 nil。
        XCTAssertNil(ZDStringDecodeBytes(Self.littleEndian(Fixture.urlID)))
    }

    func test02_InvalidInitializationDoesNotLatchTheRuntime() {
        // key 长度必须是 32 字节。
        XCTAssertThrowsError(try ZDObf.initialize(blob: Fixture.blob, key: Data(repeating: 0, count: 16))) {
            XCTAssertEqual($0 as? ZDObfError, .invalidArgument)
        }
        // 错误的 key：整个目录无法通过认证。
        XCTAssertThrowsError(try ZDObf.initialize(blob: Fixture.blob, key: Data(repeating: 0xff, count: 32))) {
            XCTAssertEqual($0 as? ZDObfError, .authenticationFailed)
        }
        // 不是 Blob 的数据。
        XCTAssertThrowsError(try ZDObf.initialize(blob: Data("not a blob".utf8), key: Fixture.key)) {
            XCTAssertEqual($0 as? ZDObfError, .malformedBlob)
        }
        // 被篡改的 Blob（翻转最后一个字节）。
        var tampered = Fixture.blob
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try ZDObf.initialize(blob: tampered, key: Fixture.key)) {
            XCTAssertEqual($0 as? ZDObfError, .authenticationFailed)
        }
        // 以上失败都不应占用单例。
        XCTAssertThrowsError(try ZDObf.string(for: Fixture.urlID)) {
            XCTAssertEqual($0 as? ZDObfError, .notInitialized)
        }
    }

    func test03_InitializeAndQuery() throws {
        try ZDObf.initialize(blob: Fixture.blob, key: Fixture.key)

        XCTAssertEqual(try ZDObf.string(for: Fixture.urlID), Fixture.urlValue)
        XCTAssertEqual(try ZDObf.string(for: Fixture.unicodeID), Fixture.unicodeValue)
        XCTAssertEqual(try ZDObf.string(for: Fixture.emptyID), Fixture.emptyValue)

        // 构建生成的源码通过 ZDStringDecodeBytes 解码 8 字节小端 ID。
        XCTAssertEqual(ZDStringDecodeBytes(Self.littleEndian(Fixture.urlID)), Fixture.urlValue)
        XCTAssertEqual(ZDStringDecodeBytes(Self.littleEndian(Fixture.emptyID)), "")
        XCTAssertNil(ZDStringDecodeBytes([1, 2, 3]), "ID 必须正好是 8 字节")

        XCTAssertThrowsError(try ZDObf.string(for: 0xdead_beef)) {
            XCTAssertEqual($0 as? ZDObfError, .invalidID)
        }
        XCTAssertNil(ZDStringDecodeBytes(Self.littleEndian(0xdead_beef)))
    }

    func test04_RuntimeCanOnlyBeInitializedOnce() {
        XCTAssertThrowsError(try ZDObf.initialize(blob: Fixture.blob, key: Fixture.key)) {
            XCTAssertEqual($0 as? ZDObfError, .alreadyInitialized)
        }
        // 重复初始化失败不影响已有目录。
        XCTAssertEqual(try? ZDObf.string(for: Fixture.urlID), Fixture.urlValue)
    }

    func test05_EmbeddedInitializationFailsWithoutASection() {
        // 内嵌 key 模式（无参）同样需要 section，缺失时报 malformedBlob。
        XCTAssertThrowsError(try ZDObf.initializeEmbedded()) {
            XCTAssertEqual($0 as? ZDObfError, .malformedBlob)
        }
        // 测试进程里没有链接 __DATA,__zdstring（见 Examples/ZDObfDemo 的端到端用法）。
        XCTAssertThrowsError(try ZDObf.initializeEmbedded(key: Fixture.key)) {
            XCTAssertEqual($0 as? ZDObfError, .malformedBlob)
        }
    }

    private static func littleEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }
}
