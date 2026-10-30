import Foundation
import Testing
import TetherCore

@Suite struct JSONStoreTests {
    /// A damaged file is moved aside, never overwritten by the next save.
    @Test func damagedFileIsKeptAside() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-json-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hosts.json")
        try Data("{ not json".utf8).write(to: url)
        let store = JSONStore<[String]>(url: url)
        #expect(store.load() == nil)
        store.save(["new"])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let aside = try #require(names.first { $0.hasPrefix("hosts.unreadable-") })
        #expect(try String(contentsOf: dir.appendingPathComponent(aside), encoding: .utf8) == "{ not json")
        #expect(store.load() == ["new"])
    }

    /// A deferred write that failed is kept and done later (at the latest at quit), not dropped.
    @Test func failedDeferredWriteIsTriedAgain() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-json-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONStore<[String]>(url: dir.appendingPathComponent("state.json"))
        store.saveSoon(["kept"])
        DeferredWrites.shared.flush()                 // its folder is not there: it fails
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.json").path))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DeferredWrites.shared.flush()
        #expect(store.load() == ["kept"])
    }

    @Test func missingFileIsNotAnError() {
        let store = JSONStore<[String]>(url: FileManager.default.temporaryDirectory.appendingPathComponent("tether-none-\(UUID()).json"))
        #expect(store.load() == nil)
    }
}

@Suite struct InstanceLockTests {
    @Test func secondCopyCannotTakeTheLock() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-lock-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!InstanceLock.isHeld(in: dir))
        let fd = open(dir.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, 0o600)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)                       // another copy holds it
        #expect(InstanceLock.isHeld(in: dir))
        flock(fd, LOCK_UN)
        #expect(!InstanceLock.isHeld(in: dir))
    }
}
