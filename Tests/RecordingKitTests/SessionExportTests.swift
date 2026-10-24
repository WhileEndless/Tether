import Foundation
import CryptoKit
import Testing
@testable import RecordingKit
@testable import SearchKit

/// ⌘S saves a whole session: older output from the recording, then what is still in memory — each
/// line once — or the raw recording. Keys are passed explicitly (never the app-wide key).
@Suite struct SessionExportTests {
    let key = SymmetricKey(size: .bits256)

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-save-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func record(_ lines: [String], in dir: URL) -> URL {
        let recorder = SessionRecorder(targetKey: "host", sessionID: UUID(), directory: dir, key: key)!
        for (i, line) in lines.enumerated() {
            recorder.append(Array(("\u{1b}[32m" + line + "\u{1b}[0m\r\n").utf8))
            if i % 50 == 0 { recorder.flushNow() }
        }
        recorder.close()
        return recorder.url
    }

    @Test func textJoinsRecordingAndScrollbackWithoutRepeats() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let all = (1...10_000).map { "line \($0)" }
        let recording = record(all, in: dir)
        // The terminal still holds the last 300 lines (as it shows them now).
        let inMemory = Array(all.suffix(300))
        let out = dir.appendingPathComponent("saved.txt")
        try SessionExport.writeText(recording: recording, dropLast: 300, lines: inMemory, to: out, key: key)
        let saved = try String(contentsOf: out, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(Array(saved.dropLast()) == all.map { Substring($0) })   // every line once, no colors
        #expect(saved.last == "")
        // Only the saved file is left in the folder (no partial file).
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }.isEmpty)
    }

    /// Output after the moment of saving (the session goes on) is not mixed in or repeated.
    @Test func stopsWhereTheRecordingWasWhenSaved() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = SessionRecorder(targetKey: "host", sessionID: UUID(), directory: dir, key: key)!
        for i in 1...100 { recorder.append(Array("line \(i)\r\n".utf8)) }
        let length = recorder.flushedLength()
        let inMemory = (91...100).map { "line \($0)" }
        for i in 101...150 { recorder.append(Array("line \(i)\r\n".utf8)) }   // arrives while saving
        recorder.flushNow()
        let out = dir.appendingPathComponent("saved.txt")
        try SessionExport.writeText(recording: recorder.url, length: length, dropLast: 10, lines: inMemory, to: out, key: key)
        let saved = try String(contentsOf: out, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(saved == (1...100).map { "line \($0)" })
        let raw = dir.appendingPathComponent("saved.log")
        try SessionExport.writeRaw(recording: recorder.url, length: length, to: raw, key: key)
        #expect(try Data(contentsOf: raw).count == length)
        recorder.close()
    }

    /// The length counts output, not file bytes, and carries over when a recording is reopened.
    @Test func recorderLengthCountsOutputAcrossReopen() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for k in [key, nil] as [SymmetricKey?] {
            let first = SessionRecorder(targetKey: "host", sessionID: UUID(), directory: dir, key: k)!
            first.append(Array("hello\r\n".utf8))
            #expect(first.flushedLength() == 7)
            first.close()
            if k == nil {
                let again = SessionRecorder(existing: first.url)!
                again.append(Array("more\r\n".utf8))
                #expect(again.flushedLength() == 13)
                again.close()
            }
        }
    }

    @Test func textWithoutRecordingIsTheScrollback() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("saved.txt")
        try SessionExport.writeText(recording: nil, dropLast: 0, lines: ["$ ls", "a b"], to: out)
        #expect(try String(contentsOf: out, encoding: .utf8) == "$ ls\na b\n")
    }

    @Test func rawKeepsTheBytesAndReplacesOnlyWhenComplete() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let recording = record(["one", "two"], in: dir)
        let out = dir.appendingPathComponent("saved.log")
        try "old".write(to: out, atomically: true, encoding: .utf8)
        try SessionExport.writeRaw(recording: recording, to: out, key: key)
        #expect(try String(contentsOf: out, encoding: .utf8) == "\u{1b}[32mone\u{1b}[0m\r\n\u{1b}[32mtwo\u{1b}[0m\r\n")
        // A recording that cannot be read leaves the existing file as it was, and nothing else.
        let wrongKey = SymmetricKey(size: .bits256)
        #expect(throws: (any Error).self) { try SessionExport.writeRaw(recording: recording, to: out, key: wrongKey) }
        #expect(try String(contentsOf: out, encoding: .utf8).hasPrefix("\u{1b}[32mone"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".partial") }.isEmpty)
    }

    @Test func suggestedNamesAreSafe() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let name = SessionExport.suggestedName(host: "web-01", title: "deploy: /srv/app", date: date, format: .text)
        #expect(name.hasPrefix("web-01 - deploy- -srv-app "))
        #expect(name.hasSuffix(".txt"))
        #expect(!name.contains("/"))
        #expect(SessionExport.suggestedName(host: "web-01", title: "web-01", date: date, format: .raw).hasPrefix("web-01 2"))
    }
}
