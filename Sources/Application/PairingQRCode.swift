import Foundation
import Compression
import Domain

/// Compact QR transport for the existing public pairing payload. The encoded JSON stays
/// byte-for-byte identical after import, so invitation digests and protocol checks still apply.
public enum PairingQRCode {
    private static let prefix = "CPS1:"
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".utf8)

    public static func encode(_ payload: String) throws -> String {
        guard let source = Data(base64Encoded: payload), !source.isEmpty, source.count < 32_000 else { throw SpaceError.invalidInput }
        let capacity = source.count + 512
        var output = Data(count: capacity)
        let size = source.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          input.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard size > 0 else { throw SpaceError.invalidInput }
        output.count = size
        var encoded = [UInt8](); encoded.reserveCapacity((output.count * 3 + 1) / 2)
        let bytes = [UInt8](output)
        var index = 0
        while index + 1 < bytes.count {
            let value = Int(bytes[index]) * 256 + Int(bytes[index + 1])
            encoded.append(alphabet[value % 45])
            encoded.append(alphabet[(value / 45) % 45])
            encoded.append(alphabet[value / 2_025])
            index += 2
        }
        if index < bytes.count {
            let value = Int(bytes[index])
            encoded.append(alphabet[value % 45]); encoded.append(alphabet[value / 45])
        }
        return prefix + String(decoding: encoded, as: UTF8.self)
    }

    public static func decode(_ scanned: String) throws -> String {
        guard scanned.hasPrefix(prefix) else { throw SpaceError.invalidInput }
        let encoded = [UInt8](scanned.dropFirst(prefix.count).utf8)
        guard !encoded.isEmpty, encoded.count < 48_000, encoded.count % 3 != 1 else { throw SpaceError.invalidInput }
        func digit(_ byte: UInt8) throws -> Int {
            guard let index = alphabet.firstIndex(of: byte) else { throw SpaceError.invalidInput }
            return index
        }
        var source = Data(); source.reserveCapacity(encoded.count * 2 / 3)
        var index = 0
        while index + 2 < encoded.count {
            let value = try digit(encoded[index]) + 45 * digit(encoded[index + 1]) + 2_025 * digit(encoded[index + 2])
            guard value <= 65_535 else { throw SpaceError.invalidInput }
            source.append(UInt8(value / 256)); source.append(UInt8(value % 256))
            index += 3
        }
        if index < encoded.count {
            let value = try digit(encoded[index]) + 45 * digit(encoded[index + 1])
            guard value <= 255 else { throw SpaceError.invalidInput }
            source.append(UInt8(value))
        }
        guard source.count < 32_000 else { throw SpaceError.invalidInput }
        let capacity = 32_000
        var output = Data(count: capacity)
        let size = source.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          input.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard size > 0, size < capacity else { throw SpaceError.invalidInput }
        output.count = size
        return output.base64EncodedString()
    }
}
