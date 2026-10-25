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
///
/// Written while Tether is locked (no recording key in memory), sealed to its public half instead
/// (`RecordingCrypto.LockedSealing`, HPKE); opening still needs the recording key:
///
///     "TETHBOX2" · key id (8) · HPKE encapsulated key (32) · ciphertext + tag
public enum SealedData {
    static let magic = Data("TETHBOX1".utf8)
    static let lockedMagic = Data("TETHBOX2".utf8)

    public static func isSealed(_ data: Data) -> Bool {
        let head = data.prefix(magic.count)
        return head == magic || head == lockedMagic
    }

    /// Seals to the public key (while locked).
    public static func seal(_ plain: Data, to sealing: RecordingCrypto.LockedSealing) -> Data? {
        guard let recipient = sealing.recipient,
              var sender = try? HPKE.Sender(recipientKey: recipient, ciphersuite: RecordingCrypto.hpkeSuite, info: RecordingCrypto.hpkeInfo)
        else { return nil }
        let head = lockedMagic + sealing.keyID + sender.encapsulatedKey
        guard let box = try? sender.seal(plain, authenticating: head) else { return nil }
        return head + box
    }

    public static func seal(_ plain: Data, key: SymmetricKey) -> Data? {
        let head = magic + RecordingCrypto.keyID(key)
        guard let box = try? AES.GCM.seal(plain, using: RecordingCrypto.subkey(key, "box"), authenticating: head).combined else { return nil }
        return head + box
    }

    /// The plain contents: `data` itself when it is not sealed.
    public static func open(_ data: Data, key: SymmetricKey?) throws -> Data {
        guard isSealed(data) else { return data }
        guard let key else { throw RecordingCrypto.Failure.locked }
        if data.prefix(lockedMagic.count) == lockedMagic { return try openLocked(data, key: key) }
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

    private static func openLocked(_ data: Data, key: SymmetricKey) throws -> Data {
        let headSize = lockedMagic.count + 8 + 32
        guard data.count > headSize else { throw RecordingCrypto.Failure.corrupt }
        let head = Data(data.prefix(headSize))
        guard head.subdata(in: 8..<16) == RecordingCrypto.keyID(key) else { throw RecordingCrypto.Failure.wrongKey }
        do {
            var recipient = try HPKE.Recipient(privateKey: RecordingCrypto.privateKey(for: key), ciphersuite: RecordingCrypto.hpkeSuite,
                                               info: RecordingCrypto.hpkeInfo, encapsulatedKey: head.subdata(in: 16..<48))
            return try recipient.open(Data(data.dropFirst(headSize)), authenticating: head)
        } catch {
            throw RecordingCrypto.Failure.corrupt
        }
    }
}
