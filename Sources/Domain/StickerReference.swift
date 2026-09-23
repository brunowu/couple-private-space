import Foundation

/// A compact chat payload for stickers installed identically on both devices.
public enum StickerReference {
    private static let prefix = "couple-private-sticker:v1:"

    public static func message(for stickerID: String) -> String? {
        guard isValid(stickerID) else { return nil }
        return prefix + stickerID
    }

    public static func stickerID(from message: String) -> String? {
        guard message.hasPrefix(prefix) else { return nil }
        let id = String(message.dropFirst(prefix.count))
        return isValid(id) ? id : nil
    }

    private static func isValid(_ id: String) -> Bool {
        guard id.hasPrefix("sha256:") else { return false }
        let digest = id.dropFirst(7)
        return digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }
}
