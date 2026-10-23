import Foundation
import Testing
@testable import MonitorKit

/// Runs the probe scripts with the local /bin/sh to catch shell syntax errors and check that
/// their output parses (the local machine stands in for a server).
@Suite struct ProbeScriptTests {
    func run(_ script: String, _ args: [String], seconds: Double) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-s", "--"] + args
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        try p.run()
        input.fileHandleForWriting.write(Data((script + "\n").utf8))
        try input.fileHandleForWriting.close()
        Thread.sleep(forTimeInterval: seconds)
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(!err.contains("syntax error"), "stderr: \(err)")
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test func streamProducesFrames() throws {
        let out = try run(ProbeScripts.systemStream, ["1"], seconds: 5)
        let frames = out.components(separatedBy: "@@end\n").filter { !$0.isEmpty }
        #expect(frames.count >= 2, "output: \(out.prefix(400))")
        let snap = ProbeParser.system(frames.first ?? "", previous: nil)
        #expect(!snap.hostname.isEmpty)
        #expect(snap.memTotal > 0)
        #expect(!snap.disks.isEmpty)
        #expect(!snap.interfaces.isEmpty)
        #expect(snap.osInfo["kernelbuild"] != nil)
        #expect(snap.osInfo["hardware"] != nil)
    }

    @Test func otherScriptsRun() throws {
        _ = try run(ProbeScripts.processes, [], seconds: 1)
        _ = try run(ProbeScripts.connections, [], seconds: 1)
        _ = try run(ProbeScripts.services, [], seconds: 2)
        _ = try run(ProbeScripts.containers, [], seconds: 1)
        _ = try run(ProbeScripts.gpuProcesses, [], seconds: 1)
        _ = try run(ProbeScripts.listening, [], seconds: 3)
    }
}
