import Foundation
import CryptoKit

/// A recording as it is at one moment: what is on disk, and the output its recorder still keeps
/// in memory (written in large batches to spare the disk). Readers that need everything shown so
/// far read it this way instead of making the recorder write early: browsing, finding and copying
/// cause no writes.
public struct RecordingSnapshot: Sendable {
    public let url: URL
    /// Bytes of output on disk at that moment (its parts included).
    public let written: Int
    /// Output not on disk yet: it comes right after `written`.
    public let pending: Data

    public init(url: URL, written: Int, pending: Data) {
        self.url = url
        self.written = written
        self.pending = pending
    }

    /// Bytes of output in all.
    public var length: Int { written + pending.count }

    /// The output from byte `from` up to `to`.
    public func bytes(from: Int, to: Int, key: SymmetricKey? = RecordingCrypto.key) -> Data {
        let to = min(to, length)
        guard to > from else { return Data() }
        var data = Data()
        if from < written { data = RecordingReader.bytes(of: url, from: from, to: min(to, written), key: key) }
        if to > written {
            let lo = max(from, written) - written, hi = to - written
            data += pending.subdata(in: (pending.startIndex + lo)..<(pending.startIndex + hi))
        }
        return data
    }

    /// Up to `count` lines ending at byte `end` (see `RecordingReader.lines(endingAt:)`).
    public func lines(endingAt end: Int, count: Int, maxBytes: Int = RecordingReader.tailMaxBytes) -> (start: Int, data: Data) {
        RecordingReader.lines(endingAt: end, count: count, maxBytes: maxBytes) { bytes(from: $0, to: $1) }
    }

    /// Up to `count` lines starting at byte `start` (see `RecordingReader.lines(startingAt:)`).
    public func lines(startingAt start: Int, count: Int, maxBytes: Int = RecordingReader.tailMaxBytes) -> (end: Int, data: Data) {
        RecordingReader.lines(startingAt: start, count: count, total: length, maxBytes: maxBytes) { bytes(from: $0, to: $1) }
    }
}
