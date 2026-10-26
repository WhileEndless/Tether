import SwiftUI

extension View {
    /// Calls `dismiss` after `seconds` without activity: the timer starts again whenever
    /// `activity` changes and waits while the pointer is over the view. 0 seconds: never.
    func autoDismiss(after seconds: Int, activity: some Equatable, dismiss: @escaping () -> Void) -> some View {
        modifier(AutoDismiss(seconds: seconds, activity: activity, dismiss: dismiss))
    }
}

private struct AutoDismiss<Activity: Equatable>: ViewModifier {
    let seconds: Int
    let activity: Activity
    let dismiss: () -> Void
    @State private var hovering = false
    @State private var timer: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0; restart() }
            .onAppear { restart() }
            .onChange(of: activity) { _, _ in restart() }
            .onChange(of: seconds) { _, _ in restart() }
            .onDisappear { timer?.cancel() }
    }

    private func restart() {
        timer?.cancel()
        guard seconds > 0, !hovering else { return }
        timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { dismiss() }
        }
    }
}
