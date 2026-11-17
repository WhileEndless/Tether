import Foundation
import Testing
@testable import SessionKit

@Suite struct TerminalOutputBufferTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tether-buffer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func spillPreservesByteOrderAndEncryptsEveryFile() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = TerminalOutputBuffer.Budget(memory: 128, disk: 1 << 20)
        let buffer = TerminalOutputBuffer(limits: .init(memory: 128, disk: 1 << 20, chunk: 64), budget: budget, root: dir)
        defer { buffer.close() }
        let input = Array(String(repeating: "private output \u{1b}[31m界\u{1b}[0m\r\n", count: 100).utf8)
        #expect(buffer.append(input[...]))
        #expect(budget.usage.memory == 128)
        #expect(budget.usage.disk > 0)
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let file as URL in files {
            guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let ciphertext = try Data(contentsOf: file)
            #expect(ciphertext.range(of: Data("private output".utf8)) == nil)
        }
        var output = Data()
        while let next = try buffer.take() { output.append(next) }
        #expect(output == Data(input))
        #expect(budget.usage.memory == 0 && budget.usage.disk == 0)
        buffer.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func applicationBudgetIsSharedAndReleasedOnClose() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = TerminalOutputBuffer.Budget(memory: 64, disk: 8192)
        let a = TerminalOutputBuffer(limits: .init(memory: 64, disk: 8192, chunk: 64), budget: budget, root: dir)
        let b = TerminalOutputBuffer(limits: .init(memory: 64, disk: 8192, chunk: 64), budget: budget, root: dir)
        defer { a.close(); b.close() }
        #expect(a.append(Array(repeating: UInt8(1), count: 64)[...]))
        #expect(b.append(Array(repeating: UInt8(2), count: 64)[...]))
        #expect(budget.usage.memory == 64)
        #expect(budget.usage.disk == 4096)
        a.close(); b.close()
        #expect(budget.usage.memory == 0 && budget.usage.disk == 0)
    }

    @Test func smallPTYReadsAreCoalescedBeforeDispatchingToTheUI() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = TerminalOutputBuffer.Budget(memory: 1 << 20, disk: 1 << 20)
        let buffer = TerminalOutputBuffer(budget: budget, root: dir)
        defer { buffer.close() }
        for _ in 0..<3000 { #expect(buffer.append(Array("line\r\n".utf8)[...])) }
        #expect(try buffer.take() == Data(String(repeating: "line\r\n", count: 3000).utf8))
        #expect(try buffer.take() == nil)
    }

    @Test func fullDiskWaitsOffMainAndCancellationUnblocksTheProducer() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = TerminalOutputBuffer.Budget(memory: 0, disk: 4096)
        let buffer = TerminalOutputBuffer(limits: .init(memory: 0, disk: 4096, chunk: 64), budget: budget, root: dir)
        defer { buffer.close() }
        #expect(buffer.append(Array(repeating: UInt8(1), count: 64)[...]))
        let producer = Task.detached { buffer.append(Array(repeating: UInt8(2), count: 64)[...]) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(budget.usage.disk == 4096)
        #expect(try buffer.take() == Data(repeating: 1, count: 64))
        #expect(await producer.value)
        let waiting = Task.detached { buffer.append(Array(repeating: UInt8(3), count: 64)[...]) }
        try await Task.sleep(for: .milliseconds(30))
        buffer.close()
        #expect(await waiting.value == false)
        #expect(budget.usage.disk == 0)
    }

    @Test func tamperingDoesNotAcknowledgeOrSkipOutput() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let budget = TerminalOutputBuffer.Budget(memory: 0, disk: 8192)
        let buffer = TerminalOutputBuffer(limits: .init(memory: 0, disk: 8192, chunk: 64), budget: budget, root: dir)
        defer { buffer.close() }
        #expect(buffer.append(Array(repeating: UInt8(7), count: 64)[...]))
        let subdirectory = try #require(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        let file = try #require(FileManager.default.contentsOfDirectory(at: subdirectory, includingPropertiesForKeys: nil).first)
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: file)
        #expect(throws: (any Error).self) { try buffer.take() }
        #expect(buffer.hasOutput)
        #expect(budget.usage.disk == 4096)
    }
}
