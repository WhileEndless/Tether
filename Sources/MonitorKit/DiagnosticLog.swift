import Foundation

/// Problems met while watching a host (a probe that failed, a tool that is missing, a file that
/// could not be written), kept quietly so the user can look at them and copy them — never printed
/// into a terminal, and never stopping anything. The same problem is counted, not repeated.
public struct DiagnosticLog: Equatable, Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        public var id = UUID()
        /// What was being done: "command", "network", "history" …
        public var source: String
        public var message: String
        public var first: Date
        public var last: Date
        public var count: Int
    }

    public private(set) var entries: [Entry] = []
    public static let limit = 50

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    /// Occurrences of all problems together.
    public var count: Int { entries.reduce(0) { $0 + $1.count } }

    public mutating func add(_ message: String, source: String, at date: Date = Date()) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let i = entries.firstIndex(where: { $0.source == source && $0.message == text }) {
            var e = entries.remove(at: i)
            e.count += 1
            e.last = date
            entries.append(e)
        } else {
            entries.append(Entry(source: source, message: text, first: date, last: date, count: 1))
            if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        }
    }

    public mutating func clear() { entries = [] }

    /// Everything as plain text, to copy into a bug report.
    public var text: String {
        let f = ISO8601DateFormatter()
        return entries.map { e in
            "\(f.string(from: e.last)) [\(e.source)] \(e.message)" + (e.count > 1 ? " (×\(e.count) since \(f.string(from: e.first)))" : "")
        }.joined(separator: "\n")
    }

    /// The last lines of a program's error output, enough to say what went wrong.
    public static func tail(_ text: String, lines: Int = 3) -> String {
        text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
    }
}
