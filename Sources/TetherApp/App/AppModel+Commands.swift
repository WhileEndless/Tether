import Foundation
import TetherCore
import SessionKit
import MonitorKit
import RecordingKit

/// The command running in each terminal and the command history.
extension AppModel {
    /// The sampler of a terminal, created on first use.
    func commandSampler(for session: TerminalSession) -> CommandSampler {
        if let s = commandSamplers[session.id] { return s }
        let target = session.descriptor.target
        let id = session.id
        let sampler = CommandSampler(anchor: { [weak session] in await session?.shellAnchor() }) { [weak session] in
            CommandSampler.Context(hostKey: target.key, hostName: target.displayName, sessionID: id,
                                   sessionTitle: session?.displayTitle ?? target.displayName)
        }
        sampler.history = commandHistory
        sampler.keepHistory = keepsCommandHistory(session)
        sampler.keepProcesses = settings.keepCommandProcesses
        sampler.keepConnections = settings.keepCommandConnections
        sampler.showLive = isEnabled(.commandStats, for: target)
        sampler.lookInterval = settings.commandLookInterval
        sampler.traffic = monitor(for: target).traffic
        commandSamplers[id] = sampler
        // One hub per host does the looking for all its terminals.
        commandHub(for: target).register(sampler)
        return sampler
    }

    /// The host's command hub (one watcher and one batched look for all its terminals).
    func commandHub(for target: ConnectionTarget) -> CommandHub {
        if let h = commandHubs[target.key] { return h }
        let h = CommandHub(executor: executor(for: target))
        h.watchEnabled = isEnabled(.commandWatch, for: target)
        h.watchInterval = settings.commandWatchInterval
        commandHubs[target.key] = h
        return h
    }

    /// At quit: watchers and looks end now (they would end on their own within seconds anyway).
    func stopCommandHubs() {
        commandHubs.values.forEach { $0.stop() }
    }

    /// A terminal went online or offline, or its foreground program changed.
    func commandStateChanged(_ session: TerminalSession) {
        if session.phase.isDead {
            commandSamplers.removeValue(forKey: session.id)?.close()
            return
        }
        let target = session.descriptor.target
        guard isEnabled(.commandHistory, for: target) || isEnabled(.commandStats, for: target) || isEnabled(.tabActivity, for: target)
            || commandSamplers[session.id] != nil else { return }
        commandSampler(for: session).update(online: session.phase.isOnline, foreground: session.foregroundName)
    }

    /// Starts watching a terminal now (when a view asks for it, whatever the settings say).
    func watchCommands(in session: TerminalSession) {
        guard !session.phase.isDead else { return }
        commandSampler(for: session).update(online: session.phase.isOnline, foreground: session.foregroundName)
    }

    /// Private sessions leave no history.
    private func keepsCommandHistory(_ session: TerminalSession) -> Bool {
        isEnabled(.commandHistory, for: session.descriptor.target) && !session.descriptor.isPrivate
    }

    func commandSessionRemoved(_ id: UUID) {
        commandSamplers.removeValue(forKey: id)?.close()
    }

    func applyCommandSettings() {
        commandHistory.retentionDays = max(settings.commandHistoryDays, 0)
        commandHistory.maxTotalBytes = max(settings.commandHistoryMaxMB, 1) * 1_048_576
        for (id, s) in commandSamplers {
            s.keepHistory = sessions.session(id).map(keepsCommandHistory) ?? false
            s.keepProcesses = settings.keepCommandProcesses
            s.keepConnections = settings.keepCommandConnections
            s.showLive = sessions.session(id).map { isEnabled(.commandStats, for: $0.descriptor.target) } ?? false
            s.lookInterval = settings.commandLookInterval
        }
        for (key, h) in commandHubs {
            h.watchEnabled = isEnabled(.commandWatch, for: target(forKey: key))
            h.watchInterval = settings.commandWatchInterval
        }
        // Turned on: terminals already online start being watched.
        for s in sessions.sessions where s.phase.isOnline { commandStateChanged(s) }
    }
}

extension CommandHistoryStore.Codec {
    /// Sealed with the recording key while recordings are encrypted (see `SealedData`); while
    /// Tether is locked, sealed to its public half, so nothing waits in memory only. A file that
    /// needs the key to be read waits until Tether is unlocked.
    static let recordingKey = Self(seal: { plain in
        guard RecordingCrypto.encryptNew else { return plain }
        if let key = RecordingCrypto.writerKey { return SealedData.seal(plain, key: key) }
        return RecordingCrypto.lockedSealing.flatMap { SealedData.seal(plain, to: $0) }
    }, open: { data in
        do {
            return .data(try SealedData.open(data, key: RecordingCrypto.key))
        } catch RecordingCrypto.Failure.locked {
            return .locked
        } catch {
            return .unreadable
        }
    })
}
