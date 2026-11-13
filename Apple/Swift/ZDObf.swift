import Foundation

// Swift 在同步 callback 内复制明文，Runtime 返回后即可 zeroize 自有缓冲区。

public enum ZDObfError: Error, Equatable {
    case invalidArgument
    case alreadyInitialized
    case notInitialized
    case invalidID
    case malformedBlob
    case authenticationFailed
    case invalidUTF8
    case allocationFailed
    case limitExceeded
    case internalError
    case unknown(UInt32)
}

public enum ZDObf {
    public static func initialize(blob: Data, key: Data) throws {
        let code = blob.withUnsafeBytes { blobBytes in
            key.withUnsafeBytes { keyBytes in
                zd_string_runtime_init(
                    blobBytes.bindMemory(to: UInt8.self).baseAddress,
                    blob.count,
                    keyBytes.bindMemory(to: UInt8.self).baseAddress,
                    key.count
                )
            }
        }
        try throwIfNeeded(code)
    }

    public static func initializeEmbedded(key: Data) throws {
        let code = key.withUnsafeBytes { keyBytes in
            zd_string_runtime_init_embedded(
                keyBytes.bindMemory(to: UInt8.self).baseAddress,
                key.count
            )
        }
        try throwIfNeeded(code)
    }

    public static func string(for id: UInt64) throws -> String {
        final class StringBox {
            var value: String?
        }
        let box = StringBox()
        let context = Unmanaged.passUnretained(box).toOpaque()
        let code = zd_string_with_utf8(id, { bytes, length, context in
            guard let context else { return ZD_STRING_ERROR_INVALID_ARGUMENT }
            let box = Unmanaged<StringBox>.fromOpaque(context).takeUnretainedValue()
            if length == 0 {
                box.value = ""
                return ZD_STRING_ERROR_OK
            }
            guard let bytes else { return ZD_STRING_ERROR_INVALID_ARGUMENT }
            box.value = String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
            return ZD_STRING_ERROR_OK
        }, context)
        try throwIfNeeded(code)
        guard let value = box.value else { throw ZDObfError.invalidUTF8 }
        return value
    }
}

// Build-generated Swift sources pass an opaque little-endian ID byte token.
public func ZDStringDecodeBytes(_ bytes: [UInt8]) -> String? {
    guard bytes.count == MemoryLayout<UInt64>.size else { return nil }
    var stringID: UInt64 = 0
    for (index, byte) in bytes.enumerated() {
        stringID |= UInt64(byte) << UInt64(index * 8)
    }
    do {
        return try ZDObf.string(for: stringID)
    } catch {
        #if DEBUG
        // 未初始化或 key/Blob 不匹配时静默返回 nil 很难排查；仅 Debug 构建输出错误（不含明文）。
        NSLog("[ZDObf] decode failed for string id 0x%llx: %@", stringID, String(describing: error))
        #endif
        return nil
    }
}

@_silgen_name("zd_string_runtime_init")
private func zd_string_runtime_init(
    _ blob: UnsafePointer<UInt8>?,
    _ blobLength: Int,
    _ key: UnsafePointer<UInt8>?,
    _ keyLength: Int
) -> UInt32

@_silgen_name("zd_string_runtime_init_embedded")
private func zd_string_runtime_init_embedded(
    _ key: UnsafePointer<UInt8>?,
    _ keyLength: Int
) -> UInt32

private typealias ZDStringUseCallback = @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> UInt32

@_silgen_name("zd_string_with_utf8")
private func zd_string_with_utf8(
    _ id: UInt64,
    _ callback: ZDStringUseCallback?,
    _ context: UnsafeMutableRawPointer?
) -> UInt32

private let ZD_STRING_ERROR_OK: UInt32 = 0
private let ZD_STRING_ERROR_INVALID_ARGUMENT: UInt32 = 1

private func throwIfNeeded(_ code: UInt32) throws {
    guard code != ZD_STRING_ERROR_OK else { return }
    switch code {
    case 1: throw ZDObfError.invalidArgument
    case 2: throw ZDObfError.alreadyInitialized
    case 3: throw ZDObfError.notInitialized
    case 4: throw ZDObfError.invalidID
    case 5: throw ZDObfError.malformedBlob
    case 6: throw ZDObfError.authenticationFailed
    case 7: throw ZDObfError.invalidUTF8
    case 8: throw ZDObfError.allocationFailed
    case 9: throw ZDObfError.limitExceeded
    case 100: throw ZDObfError.internalError
    default: throw ZDObfError.unknown(code)
    }
}
