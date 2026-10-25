import Foundation
import CryptoKit

/// Small files (such as the command history) encrypted with the recording key: written whole,
/// read whole. Plain data passes through `open` unchanged, so files written before encryption was
/// turned on stay readable.
///
///     "TETHBOX1" · key id (8) · AES-256-GCM combined box (nonce + ciphertext + tag)
///
/// The box authenticates the magic and key id too, and is sealed with a key derived for this use
/// only (never the recording key itself).
public enum SealedData {
    static let magic = Data("TETHBOX1".utf8)

    public static func isSealed(_ data: Data) -> Bool { data.prefix(magic.count) == magic }

    public static func seal(_ plain: Data, key: SymmetricKey) -> Data? {
        let head = magic + RecordingCrypto.keyID(key)
        guard let box = try? AES.GCM.seal(plain, using: RecordingCrypto.subkey(key, "box"), authenticating: head).combined else { return nil }
        return head + box
    }

    /// The plain contents: `data` itself when it is not sealed.
    public static func open(_ data: Data, key: SymmetricKey?) throws -> Data {
        guard isSealed(data) else { return data }
        guard let key else { throw RecordingCrypto.Failure.locked }
        let headSize = magic.count + 8
        guard data.count > headSize else { throw RecordingCrypto.Failure.corrupt }
        let head = Data(data.prefix(headSize))
        guard head.suffix(8) == RecordingCrypto.keyID(key) else { throw RecordingCrypto.Failure.wrongKey }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(headSize)))
            return try AES.GCM.open(box, using: RecordingCrypto.subkey(key, "box"), authenticating: head)
        } catch {
            throw RecordingCrypto.Failure.corrupt
        }
    }
}
