import Foundation

/// The items of one drag out of the file manager (to Finder, the Desktop, another app). The drop
/// target asks for each item on its own; the first request downloads all of them together — so
/// many files go as one packed stream, under the same rules as any other download — and every
/// request is answered once that download has ended: with the item's local file, or with an error
/// (failed, cancelled). Each request is answered exactly once, also one asked for after the end.
@MainActor
public final class DragDownloadSession {
    /// The local files that arrived, by remote path; `nil`: cancelled before anything was sent.
    public typealias Outcome = (arrived: [String: URL], message: String?)
    public typealias Answer = (URL?, Error?) -> Void

    /// The remote paths dragged together.
    public let paths: [String]
    public let createdAt = Date()
    private let download: (@escaping @MainActor (Outcome) -> Void) -> Void
    private var waiting: [String: [Answer]] = [:]
    private var outcome: Outcome?
    private var started = false

    /// `download` fetches every path of the drag and calls back once when all have ended.
    public init(paths: [String], download: @escaping (@escaping @MainActor (Outcome) -> Void) -> Void) {
        self.paths = paths
        self.download = download
    }

    public struct Failed: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Asks for one dragged item; `answer` is called once.
    public func request(_ path: String, answer: @escaping Answer) {
        if let outcome {
            reply(answer, path: path, outcome: outcome)
            return
        }
        waiting[path, default: []].append(answer)
        guard !started else { return }
        started = true
        // Held by its own download until it has answered: the drop's providers may be gone by
        // then (a new drag replaces the current session), and an answer must never be lost.
        download { outcome in self.finish(outcome) }
    }

    private func finish(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let all = waiting
        waiting.removeAll()
        for (path, answers) in all {
            for answer in answers { reply(answer, path: path, outcome: outcome) }
        }
    }

    private func reply(_ answer: Answer, path: String, outcome: Outcome) {
        if let url = outcome.arrived[path] {
            answer(url, nil)
        } else {
            answer(nil, Failed(message: outcome.message ?? "\((path as NSString).lastPathComponent) could not be downloaded."))
        }
    }

    /// Whether a drag of these paths, begun now, is this one (SwiftUI asks for one provider per
    /// dragged row, one after another, as the drag begins).
    public func matches(_ paths: [String], within seconds: TimeInterval = 2) -> Bool {
        !started && self.paths == paths && Date().timeIntervalSince(createdAt) < seconds
    }
}
