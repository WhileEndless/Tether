import Foundation

/// One fair UI budget for all terminals, rather than a frame budget per terminal. Producers
/// prepare their next bounded piece off the main actor and register it when it is ready.
@MainActor
public final class OutputScheduler {
    public static let shared = OutputScheduler()
    private struct Job {
        let id: UUID
        let visible: () -> Bool
        let step: () -> Bool
    }
    private var jobs: [Job] = []
    private var scheduled = false
    private var visiblePass = true

    public func enqueue(id: UUID, visible: @escaping () -> Bool, step: @escaping () -> Bool) {
        guard !jobs.contains(where: { $0.id == id }) else { return }
        jobs.append(Job(id: id, visible: visible, step: step))
        schedule()
    }

    public func cancel(id: UUID) { jobs.removeAll { $0.id == id } }

    private func schedule() {
        guard !scheduled, !jobs.isEmpty else { return }
        scheduled = true
        // A small gap also gives AppKit sources a chance to run during sustained output.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in self?.drain() }
    }

    private func drain() {
        scheduled = false
        let start = DispatchTime.now().uptimeNanoseconds
        while !jobs.isEmpty {
            let index = visiblePass ? jobs.firstIndex(where: { $0.visible() }) ?? 0 : 0
            visiblePass.toggle()
            let job = jobs.remove(at: index)
            if job.step() { jobs.append(job) }
            if DispatchTime.now().uptimeNanoseconds - start >= 4_000_000 { break }
        }
        schedule()
    }
}
