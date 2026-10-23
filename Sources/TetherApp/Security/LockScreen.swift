import SwiftUI
import TetherCore

/// Covers a window while Tether is locked.
struct LockScreen: View {
    @State private var lock = AppLock.shared
    @State private var password = ""
    @State private var wrong = false
    @State private var confirmReset = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { lock.offerSystemUnlock() }   // a click anywhere asks for Touch ID
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Tether is locked").font(.title2.weight(.semibold))
                if lock.mode == .password {
                    SecureField("Tether password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .focused($focused)
                        .onSubmit(unlock)
                        .disabled(lock.unlocking)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let wait = lock.retryAfter.map { Int(ceil($0.timeIntervalSince(context.date))) } ?? 0
                        Group {
                            if wait > 0 { Text("Wrong password. Try again in \(wait) s.") }
                            else if wrong { Text("Wrong password.") }
                            else { Text(" ") }
                        }
                        .font(.callout).foregroundStyle(.red)
                    }
                    HStack(spacing: 10) {
                        Button("Unlock", action: unlock)
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(password.isEmpty || lock.unlocking)
                        if lock.canUseSystemUnlock {
                            Button("Use \(lock.methodName)") { Task { await lock.unlockWithSystem() } }
                                .disabled(lock.unlocking)
                        }
                    }
                } else {
                    Button("Unlock with \(lock.methodName)") { Task { await lock.unlockWithSystem() } }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(lock.unlocking)
                }
                HStack(spacing: 16) {
                    if lock.mode == .password {
                        Button("Forgot Password…") { confirmReset = true }.buttonStyle(.link)
                            .help("Reset: deletes encrypted recordings, keeps sessions and settings")
                    }
                    Button("Quit Tether") { NSApp.terminate(nil) }.buttonStyle(.link)
                }
                .font(.callout)
                .padding(.top, 6)
            }
            .padding(40)
        }
        .onAppear {
            focused = true
            // One prompt for all windows (AppLock ignores repeats while one is open), and only when
            // someone is there to answer it.
            lock.offerSystemUnlock()
        }
        .sheet(isPresented: $confirmReset) { ResetSecuritySheet() }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        let attempt = password
        Task {
            let ok = await lock.unlock(password: attempt)
            wrong = !ok
            password = ""
            if !ok { focused = true }
        }
    }
}

extension View {
    /// Hides the window's content (and its toolbar) while Tether is locked.
    func appLockCover() -> some View { modifier(AppLockCover()) }
}

private struct AppLockCover: ViewModifier {
    @State private var lock = AppLock.shared

    func body(content: Content) -> some View {
        content
            .toolbar(lock.isLocked ? .hidden : .automatic, for: .windowToolbar)
            .overlay { if lock.isLocked { LockScreen() } }
    }
}
