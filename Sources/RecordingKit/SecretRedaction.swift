import Foundation
import CryptoKit
import Compression
import TetherCore

/// Masks secrets (API keys, tokens, private keys) in a recording once its session is archived.
///
/// Each secret is replaced by a mask of exactly as many bytes (`[REDACTED****]`, or `****` when it
/// is short), so a recording keeps its length: parts keep their names, positions in transcripts
/// stay right and the replay lays out the same. Lines are matched byte for byte (any bytes that
/// are not ASCII are kept as they were); a secret broken up by escape sequences or a line break
/// is not found. This is a safety net, not a guarantee.
public struct SecretRedactor: Sendable {
    struct Compiled: @unchecked Sendable {
        let regex: NSRegularExpression
        let end: NSRegularExpression?
        let usesSecretGroup: Bool
    }
    let rules: [Compiled]
    /// Lines longer than this are matched in pieces.
    static let maxLine = 1 << 20

    public init(rules: [SecretRule]) {
        self.rules = rules.compactMap { rule in
            guard rule.problem == nil, let regex = try? NSRegularExpression(pattern: rule.pattern) else { return nil }
            let end = rule.endPattern.flatMap { try? NSRegularExpression(pattern: $0) }
            if rule.endPattern != nil && end == nil { return nil }
            return Compiled(regex: regex, end: end, usesSecretGroup: rule.pattern.contains("(?<secret>"))
        }
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// The mask for `count` bytes.
    static func mask(_ count: Int) -> [UInt8] {
        guard count >= 12 else { return Array(repeating: UInt8(ascii: "*"), count: count) }
        return Array("[REDACTED".utf8) + Array(repeating: UInt8(ascii: "*"), count: count - 10) + [UInt8(ascii: "]")]
    }

    /// Masks secrets in a stream of output, line by line. Feed chunks, then `finish`.
    public struct Stream {
        let redactor: SecretRedactor
        private var line: [UInt8] = []
        /// Inside a block (a private key): the rule whose end ends it.
        private var block: NSRegularExpression?
        public private(set) var masked = 0

        init(_ redactor: SecretRedactor) { self.redactor = redactor }

        public mutating func feed(_ data: some Sequence<UInt8>) -> [UInt8] {
            var out: [UInt8] = []
            for b in data {
                line.append(b)
                if b == 0x0a || line.count >= SecretRedactor.maxLine { out += take() }
            }
            return out
        }

        public mutating func finish() -> [UInt8] { take() }

        private mutating func take() -> [UInt8] {
            defer { line.removeAll(keepingCapacity: true) }
            guard !line.isEmpty else { return [] }
            // ISO Latin 1 maps every byte to one character and back: matching never changes a byte
            // it does not mask, whatever the encoding of the output.
            var text = Self.latin1(line)
            if let end = block {
                if end.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil {
                    block = nil
                    return line
                }
                return maskBody(line)
            }
            var bytes = line
            for rule in redactor.rules {
                let ns = text as NSString
                let range = NSRange(location: 0, length: ns.length)
                if let end = rule.end {
                    // The block's first line stays (it says what was there); the end may be on it too.
                    if let m = rule.regex.firstMatch(in: text, range: range) {
                        let after = NSRange(location: m.range.upperBound, length: ns.length - m.range.upperBound)
                        if end.firstMatch(in: text, range: after) == nil { block = end }
                    }
                    continue
                }
                var changed = false
                for m in rule.regex.matches(in: text, range: range) {
                    var r = m.range
                    if rule.usesSecretGroup {
                        let g = m.range(withName: "secret")
                        if g.location != NSNotFound { r = g }
                    }
                    guard r.length > 0, !isMasked(bytes, r) else { continue }
                    bytes.replaceSubrange(r.location..<(r.location + r.length), with: SecretRedactor.mask(r.length))
                    masked += 1
                    changed = true
                }
                if changed { text = Self.latin1(bytes) }
            }
            return bytes
        }

        /// Whether the range is (inside) a mask already, so a later, wider rule leaves it alone.
        private func isMasked(_ bytes: [UInt8], _ r: NSRange) -> Bool {
            let slice = bytes[r.location..<(r.location + r.length)]
            return slice.allSatisfy { $0 == UInt8(ascii: "*") } || slice.starts(with: Array("[REDACTED".utf8))
        }

        /// A line inside a block: everything but its line ending and leading spaces is masked.
        private mutating func maskBody(_ bytes: [UInt8]) -> [UInt8] {
            var out = bytes
            for i in out.indices where ![0x0a, 0x0d, 0x20, 0x09].contains(out[i]) { out[i] = UInt8(ascii: "*") }
            if out != bytes { masked += 1 }
            return out
        }

        static func latin1(_ bytes: [UInt8]) -> String {
            String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
        }
    }

    public func stream() -> Stream { Stream(self) }

    /// Masks secrets in some bytes (for tests and small texts).
    public func redact(_ bytes: [UInt8]) -> (bytes: [UInt8], masked: Int) {
        var s = stream()
        let out = s.feed(bytes) + s.finish()
        return (out, s.masked)
    }

    public func redact(_ text: String) -> String {
        String(decoding: redact(Array(text.utf8)).bytes, as: UTF8.self)
    }
}

extension SecretRedactor {
    public enum Outcome: Equatable, Sendable {
        /// Masked this many secrets (0: nothing found, the files were left as they were).
        case done(masked: Int)
        /// Still being written, or encrypted while its key is not loaded (locked): try later.
        case notNow
        case failed
    }

    /// Masks the secrets in a recording: its parts and the file, each kept plain, compressed or
    /// encrypted as it was. Runs on the recordings' maintenance queue (never at the same time as
    /// compression or the storage limit) and leaves nothing half-written.
    public func redactRecording(at path: String, key: SymmetricKey? = RecordingCrypto.key) async -> Outcome {
        await RecordingStore.perform { [self] in redactRecordingNow(at: path, key: key) }
    }

    func redactRecordingNow(at path: String, key: SymmetricKey?) -> Outcome {
        guard let url = RecordingStore.resolve(path) else { return .done(masked: 0) }
        if RecordingStore.isActive(url) { return .notNow }
        var total = 0
        for file in RecordingParts.parts(of: url).map({ RecordingParts.current($0.url) }) + [url] {
            switch redactFile(file, key: key) {
            case .done(let n): total += n
            case let other: return other
            }
        }
        return .done(masked: total)
    }

    /// One file of a recording. The replacement is written next to it and swapped in.
    func redactFile(_ url: URL, key loaded: SymmetricKey?) -> Outcome {
        let fm = FileManager.default
        let fileKey: SymmetricKey?
        do { fileKey = try RecordingCrypto.readingKey(for: url, loaded: loaded) } catch { return .notNow }
        if RecordingCrypto.isEncrypted(url) && fileKey == nil { return .notNow }
        // Looked through first without writing anything: most files have nothing to mask, and a
        // copy of each (decrypted, recompressed, encrypted again) would be written for nothing.
        do {
            var scan = stream()
            try RecordingReader.forEachChunk(ofFile: url, key: loaded) { chunk in
                _ = scan.feed(chunk)
                return true
            }
            _ = scan.finish()
            guard scan.masked > 0 else { return .done(masked: 0) }
        } catch {
            return .failed
        }
        let tmp = url.appendingPathExtension("redact.tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: tmp) else { return .failed }
        var finished = false
        defer {
            try? output.close()
            if !finished { try? fm.removeItem(at: tmp) }
        }
        do {
            let writer = try RecordingWriter(output: output, key: fileKey, compressed: RecordingCompression.isCompressed(url))
            var stream = stream()
            try RecordingReader.forEachChunk(ofFile: url, key: loaded) { chunk in
                try writer.write(Data(stream.feed(chunk)))
                return true
            }
            try writer.write(Data(stream.finish()))
            try writer.finish()
            guard stream.masked > 0 else { return .done(masked: 0) }    // nothing to change: the file stays
            try output.close()
            let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
            finished = true
            if let date { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
            return .done(masked: stream.masked)
        } catch {
            return .failed
        }
    }
}

/// Writes a recording file in a given form: compressed or not, encrypted with a key or plain.
final class RecordingWriter {
    private let output: FileHandle
    private let sealer: RecordingCrypto.Sealer?
    private var filter: OutputFilter?
    private var pending = Data()
    private var index = 0

    init(output: FileHandle, key: SymmetricKey?, compressed: Bool) throws {
        self.output = output
        let file = key.map(RecordingCrypto.newFile)
        sealer = file?.sealer
        if let file { try output.write(contentsOf: file.header) }
        if compressed {
            filter = try OutputFilter(.compress, using: .lzfse) { [unowned self] data in
                if let data { try self.emit(data, final: false) }
            }
        }
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        if let filter { try filter.write(data) } else { try emit(data, final: false) }
    }

    func finish() throws {
        try filter?.finalize()
        try emit(Data(), final: true)
    }

    private func emit(_ data: Data, final: Bool) throws {
        guard let sealer else { try output.write(contentsOf: data); return }
        pending += data
        while pending.count >= RecordingCrypto.fileFrameBytes || (final && !pending.isEmpty) {
            let chunk = pending.prefix(RecordingCrypto.fileFrameBytes)
            pending.removeFirst(chunk.count)
            guard let f = RecordingCrypto.frame(Data(chunk), sealer: sealer, index: index) else { throw RecordingCrypto.Failure.corrupt }
            try output.write(contentsOf: f)
            index += 1
        }
    }
}
