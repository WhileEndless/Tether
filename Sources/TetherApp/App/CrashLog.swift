import Foundation
import AppKit
import ObjectiveC

/// Writes uncaught exceptions and fatal signals with their call stacks to the file named by
/// TETHER_CRASH_LOG (diagnostics only; off unless the variable is set).
enum CrashLog {
    nonisolated(unsafe) private static var fd: Int32 = -1
    nonisolated(unsafe) static var previousPreprocessor: objc_exception_preprocessor?

    static func installIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["TETHER_CRASH_LOG"] else { return }
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        // Every Objective-C exception at the point it is thrown (AppKit catches some of them
        // during layout and then traps, so the uncaught handler never sees those).
        previousPreprocessor = objc_setExceptionPreprocessor { obj in
            if let e = obj as? NSException {
                CrashLog.write("Thrown \(e.name.rawValue): \(e.reason ?? "")\n" + Thread.callStackSymbols.prefix(60).joined(separator: "\n") + "\n")
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        for w in NSApp.windows { if let v = w.contentView?.superview ?? w.contentView { CrashLog.dump(v, 0) } }
                    }
                }
            }
            return CrashLog.previousPreprocessor?(obj) ?? obj
        }
        NSSetUncaughtExceptionHandler { e in
            CrashLog.write("Exception \(e.name.rawValue): \(e.reason ?? "")\n" + e.callStackSymbols.joined(separator: "\n") + "\n")
        }
        for sig in [SIGTRAP, SIGABRT, SIGSEGV, SIGBUS, SIGILL] {
            signal(sig) { s in
                CrashLog.write("Signal \(s)\n" + Thread.callStackSymbols.joined(separator: "\n") + "\n")
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    /// Views that want another constraints pass (the ones keeping a layout loop going).
    @MainActor static func dump(_ v: NSView, _ depth: Int) {
        if v.needsUpdateConstraints || v.needsLayout {
            write(String(repeating: " ", count: depth) + "\(type(of: v)) frame=\(v.frame) updC=\(v.needsUpdateConstraints) layout=\(v.needsLayout) tamic=\(v.translatesAutoresizingMaskIntoConstraints)\n")
        }
        for s in v.subviews { dump(s, depth + 1) }
    }

    static func write(_ text: String) {
        guard fd >= 0 else { return }
        text.utf8CString.withUnsafeBufferPointer { p in _ = Darwin.write(fd, p.baseAddress, p.count - 1) }
    }
}
