import Foundation
import SwiftTerm
import SSHTransport

/// SwiftTerm calls this adapter on a private serial queue. Its synchronous delivery naturally
/// pauses the PTY reader if the encrypted buffer reaches its limit, without blocking AppKit.
final class ProcessBridge: LocalProcessDelegate, @unchecked Sendable {
    let deliveryQueue = DispatchQueue(label: "terminal input", qos: .userInitiated)
    private let readerQueue = DispatchQueue(label: "terminal buffer reader", qos: .userInitiated)
    private let buffer = TerminalOutputBuffer()
    private let lock = NSLock()
    private var reading = false
    private var more = false
    private var cancelled = false
    private var ended = false
    private var exitCode: Int32?
    private var lastReceive = DispatchTime.now().uptimeNanoseconds
    private var exitObserved: UInt64 = 0
    // Accessed only by deliveryQueue. Batch tiny PTY reads before allocating queue entries or
    // encrypted files; interactive output is held for at most four milliseconds.
    private var incoming: [UInt8] = []
    private var flushGeneration = 0
    private var flushScheduled = false
    private var size: winsize
    private let jobID = UUID()
    @MainActor weak var owner: TerminalSession?
    @MainActor weak var process: LocalProcess?
    @MainActor private var ready: [UInt8] = []
    @MainActor private var readyOffset = 0

    @MainActor init(owner: TerminalSession) {
        self.owner = owner
        size = owner.windowSize
    }

    deinit {
        let buffer = buffer
        readerQueue.async { buffer.close() }
    }

    func updateSize(_ size: winsize) { lock.withLock { self.size = size } }

    @MainActor func cancel() {
        guard lock.withLock({
            guard !cancelled else { return false }
            cancelled = true
            return true
        }) else { return }
        OutputScheduler.shared.cancel(id: jobID)
        ready.removeAll(); readyOffset = 0
        // Cleanup can wait for a disk operation; never hold the main actor behind that lock.
        let buffer = buffer
        readerQueue.async { buffer.close() }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        guard !lock.withLock({ cancelled }) else { return }
        lock.withLock { lastReceive = DispatchTime.now().uptimeNanoseconds }
        incoming.append(contentsOf: slice)
        if incoming.count >= 64 << 10 { flushInput(); return }
        guard !flushScheduled else { return }
        flushScheduled = true
        let generation = flushGeneration
        deliveryQueue.asyncAfter(deadline: .now() + 0.004) { [weak self] in
            guard let self, self.flushGeneration == generation else { return }
            self.flushInput()
        }
    }

    private func flushInput() {
        flushGeneration += 1
        flushScheduled = false
        let bytes = incoming
        incoming.removeAll(keepingCapacity: true)
        guard !bytes.isEmpty, !lock.withLock({ cancelled }) else { return }
        buffer.append(bytes[...]) { [weak self] in self?.requestRead() }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        lock.withLock { self.exitCode = exitCode; exitObserved = DispatchTime.now().uptimeNanoseconds }
        // The exit notification can precede the final PTY reads. Keep the process (and its
        // DispatchIO) alive until EOF. An orphan holding the slave open cannot hold the UI's
        // session-ended state forever: two seconds with no further bytes is the fallback.
        deliveryQueue.async { [weak self] in self?.finishAfterEOF(source) }
    }

    private func finishAfterEOF(_ source: LocalProcess) {
        flushInput()
        let state = lock.withLock { (cancelled, max(lastReceive, exitObserved)) }
        guard !state.0 else { return }
        if source.childfd == -1 || DispatchTime.now().uptimeNanoseconds - state.1 >= 2_000_000_000 {
            lock.withLock { ended = true }
            requestRead()
        } else {
            deliveryQueue.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.finishAfterEOF(source) }
        }
    }

    func getWindowSize() -> winsize { lock.withLock { size } }

    private func requestRead() {
        guard lock.withLock({
            guard !cancelled else { return false }
            guard !reading else { more = true; return false }
            reading = true
            more = false
            return true
        }) else { return }
        readerQueue.async { [weak self] in
            guard let self else { return }
            do {
                let bytes = try self.buffer.take()
                DispatchQueue.main.async { [weak self] in self?.received(bytes) }
            } catch {
                // Authentication or read errors must never silently skip output. End this
                // connection through the existing failure/reconnect flow, keeping the UI usable.
                DispatchQueue.main.async { [weak self] in self?.failed() }
            }
        }
    }

    @MainActor private func received(_ data: Data?) {
        guard !lock.withLock({ cancelled }), let owner, owner.isCurrent(process) else { cancel(); return }
        if let data, !data.isEmpty {
            ready = Array(data)
            readyOffset = 0
            OutputScheduler.shared.enqueue(id: jobID, visible: { [weak self] in self?.owner?.isOnScreen == true }) { [weak self] in
                self?.step() ?? false
            }
            return
        }
        let end = lock.withLock { () -> (Bool, Int32?, Bool) in reading = false; return (ended, exitCode, more) }
        if end.2 { requestRead(); return }
        if end.0 {
            owner.processTerminated(exitCode: TerminalSession.exitStatus(fromWaitStatus: end.1))
            cancel()
        }
    }

    @MainActor private func step() -> Bool {
        guard !lock.withLock({ cancelled }), let owner, owner.isCurrent(process) else { cancel(); return false }
        let end = min(readyOffset + 2048, ready.count)
        owner.processOutput(ready[readyOffset..<end])
        readyOffset = end
        if end < ready.count { return true }
        ready.removeAll(keepingCapacity: true)
        readyOffset = 0
        lock.withLock { reading = false }
        requestRead()
        return false
    }

    @MainActor private func failed() {
        guard let owner, owner.isCurrent(process) else { cancel(); return }
        ConnectionLog.shared.notice("The temporary terminal output buffer could not be read; the connection was stopped", .tab)
        let process = process
        owner.processTerminated(exitCode: 255)
        process?.terminate()
        cancel()
    }

}
