import Foundation
import CryptoKit
import Testing
@testable import RecordingKit
import TetherCore

/// Secrets are masked in archived recordings, byte for byte the same length, in every form a
/// recording can have. The secrets below are made up and put together at run time, so no
/// token-shaped text is in the repository for scanners to report.
@Suite struct SecretRedactionTests {
    let redactor = SecretRedactor(rules: SecretRedactionSettings().activeRules)

    /// A fake value: `prefix` and `count` characters cycling through letters and digits.
    static func fake(_ prefix: String, _ count: Int, alphabet: String = "abcdefghijklmnopqrstuvwxyz0123456789") -> String {
        let chars = Array(alphabet)
        return prefix + String((0..<count).map { chars[($0 * 7) % chars.count] })
    }
    let github = fake("gh" + "p_", 36)
    let aws = fake("AK" + "IA", 16, alphabet: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    let openai = fake("sk" + "-proj-", 40)
    let anthropic = fake("sk" + "-ant-api03-", 60)

    @Test func knownFormatsAreMaskedAtTheSameLength() {
        for secret in [github, aws, openai, anthropic] {
            let line = "token: \(secret) end\r\n"
            let out = redactor.redact(line)
            #expect(!out.contains(secret), "\(secret.prefix(6))…")
            #expect(out.utf8.count == line.utf8.count)
            #expect(out.hasPrefix("token: ") && out.hasSuffix(" end\r\n"))
        }
        #expect(redactor.redact("\(github)\n") == "[REDACTED" + String(repeating: "*", count: github.count - 10) + "]\n")
    }

    @Test func onlyTheValueOfAnAssignmentIsMasked() {
        let value = Self.fake("v", 20)
        #expect(redactor.redact("export MY_API_KEY=\(value)\n") == "export MY_API_KEY=" + String(SecretRedactor.mask(21).map { Character(Unicode.Scalar($0)) }) + "\n")
        #expect(redactor.redact("psql postgres://user:\(value)@db.example.com/app\n")
                == "psql postgres://user:" + String(SecretRedactor.mask(21).map { Character(Unicode.Scalar($0)) }) + "@db.example.com/app\n")
        // Ordinary output stays as it is.
        let plain = "ls -la\ntotal 0\npassword: \nToken refresh in 5 s\n"
        #expect(redactor.redact(plain) == plain)
    }

    @Test func privateKeyBlocksAreMasked() {
        let body = (0..<3).map { _ in Self.fake("M", 63, alphabet: "ABCDEFGHabcdefgh0123+/") }
        let begin = "-----BEGIN OPENSSH " + "PRIVATE KEY-----", end = "-----END OPENSSH " + "PRIVATE KEY-----"
        let text = "$ cat id\r\n\(begin)\r\n" + body.map { $0 + "\r\n" }.joined() + "\(end)\r\n$ ls\r\n"
        let out = redactor.redact(text)
        #expect(out.utf8.count == text.utf8.count)
        for line in body { #expect(!out.contains(line)) }
        #expect(out.contains(begin) && out.contains(end) && out.hasSuffix("$ ls\r\n"))
    }

    @Test func bytesThatAreNotTextAreKept() {
        let bytes: [UInt8] = [0xff, 0xfe, 0x1b, 0x5b, 0x33, 0x31, 0x6d] + Array("é \(github)".utf8) + [0x80, 0x0a]
        let (out, n) = redactor.redact(bytes)
        #expect(n == 1)
        #expect(out.count == bytes.count)
        #expect(Array(out.prefix(9)) == Array(bytes.prefix(9)))
        #expect(out.last == 0x0a && out[out.count - 2] == 0x80)
    }

    @Test func userRulesExtendTheListAndBuiltInsCanBeSwitchedOff() {
        var settings = SecretRedactionSettings()
        settings.custom = [SecretRule(name: "Ticket", pattern: #"INTERNAL-[0-9]{6}"#),
                           SecretRule(name: "Broken", pattern: "(")]
        settings.disabledBuiltIns = ["github-token"]
        let r = SecretRedactor(rules: settings.activeRules)
        #expect(r.redact("INTERNAL-123456 \(github)\n") == "[REDACTED*****] \(github)\n")
        #expect(r.redact("x INTERNAL-12345 y\n") == "x INTERNAL-12345 y\n")
        settings.enabled = false
        #expect(settings.activeRules.isEmpty)
        #expect(SecretRule(name: "x", pattern: "a*").problem != nil)      // matches empty text
    }

    @Test func builtInRulesAreValid() {
        for rule in SecretRule.builtIn { #expect(rule.problem == nil, "\(rule.id)") }
        #expect(Set(SecretRule.builtIn.map(\.id)).count == SecretRule.builtIn.count)
    }

    // MARK: Files

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("tether-redact-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func read(_ url: URL, key: SymmetricKey?) throws -> Data {
        var data = Data()
        try RecordingReader.forEachChunk(of: url, key: key) { data += $0; return true }
        return data
    }

    /// A recording of many lines with a secret in some of them, in parts of `partBytes` (0: none).
    func record(in dir: URL, key: SymmetricKey?, partBytes: Int = 0) -> (URL, Data) {
        let recorder = SessionRecorder(targetKey: "host", sessionID: UUID(), directory: dir, key: key)!
        recorder.partBytes = partBytes
        var all = Data()
        for i in 0..<3_000 {
            let line = Data((i % 500 == 7 ? "export TOKEN=\(github)\r\n" : "line \(i) \(String(repeating: "x", count: 60))\r\n").utf8)
            all += line
            recorder.append(line)
            if i % 100 == 0 { recorder.flushNow() }
        }
        recorder.close()
        RecordingStore.waitForMaintenance()
        return (recorder.url, all)
    }

    @Test(arguments: [false, true])
    func recordingsKeepTheirFormAndLength(encrypted: Bool) async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = encrypted ? SymmetricKey(size: .bits256) : nil
        let (url, all) = record(in: dir, key: key, partBytes: 64 * 1024)
        let parts = RecordingParts.parts(of: url)
        #expect(!parts.isEmpty)
        let compressed = try RecordingCompression.compress(url, key: key, encryptPlain: false)

        let outcome = await redactor.redactRecording(at: url.path, key: key)
        #expect(outcome == .done(masked: 6))
        let after = try read(compressed, key: key)
        #expect(after.count == all.count)
        #expect(after.range(of: Data(github.utf8)) == nil)
        #expect(String(decoding: after, as: UTF8.self).contains("line 2999 "))
        #expect(RecordingParts.parts(of: compressed).map(\.url.lastPathComponent) == parts.map { RecordingParts.current($0.url).lastPathComponent })
        #expect(RecordingCrypto.isEncrypted(compressed) == encrypted)
        #expect(RecordingCompression.isCompressed(compressed))
        // Nothing left behind, and a second pass finds nothing.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("host").path).allSatisfy { !$0.hasSuffix(".tmp") })
        #expect(await redactor.redactRecording(at: url.path, key: key) == .done(masked: 0))
    }

    @Test func encryptedRecordingWaitsForItsKey() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let (url, _) = record(in: dir, key: key)
        #expect(await redactor.redactRecording(at: url.path, key: nil) == .notNow)
        #expect(try read(url, key: key).range(of: Data(github.utf8)) != nil)
        #expect(await redactor.redactRecording(at: url.path, key: key) == .done(masked: 6))
    }

    @Test func recordingStillBeingWrittenIsLeftAlone() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = SessionRecorder(targetKey: "host", sessionID: UUID(), directory: dir, key: nil)!
        recorder.append(Array("TOKEN=\(github)\r\n".utf8))
        recorder.flushNow()
        #expect(await redactor.redactRecording(at: recorder.url.path, key: nil) == .notNow)
        recorder.close()
        #expect(await redactor.redactRecording(at: recorder.url.path, key: nil) == .done(masked: 1))
    }
}
