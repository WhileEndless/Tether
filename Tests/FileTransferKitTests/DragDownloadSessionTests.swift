import Foundation
import Testing
@testable import FileTransferKit

/// Files dragged out together are downloaded together, and every item the drop asks for is
/// answered exactly once.
@MainActor @Suite struct DragDownloadSessionTests {
    final class Box {
        var starts = 0
        var finish: ((DragDownloadSession.Outcome) -> Void)?
        var answers: [String: [String]] = [:]
    }

    private func session(_ paths: [String], _ box: Box) -> DragDownloadSession {
        DragDownloadSession(paths: paths) { done in
            box.starts += 1
            box.finish = done
        }
    }

    private func ask(_ s: DragDownloadSession, _ path: String, _ box: Box) {
        s.request(path) { url, error in
            box.answers[path, default: []].append(url?.lastPathComponent ?? "error: \(error?.localizedDescription ?? "")")
        }
    }

    @Test func oneDownloadForTheWholeDragAndOneAnswerEach() {
        let box = Box()
        let paths = (0..<300).map { "/srv/logs/f\($0).log" }
        let s = session(paths, box)
        for p in paths.prefix(200) { ask(s, p, box) }
        ask(s, paths[0], box)                       // asked twice: answered twice, once per request
        #expect(box.starts == 1)
        #expect(box.answers.isEmpty, "nothing is answered before the download ended")
        var arrived: [String: URL] = [:]
        for p in paths where p != paths[7] { arrived[p] = URL(fileURLWithPath: "/tmp/x/" + (p as NSString).lastPathComponent) }
        box.finish?((arrived, "f7.log: Permission denied"))
        box.finish?((arrived, nil))                 // a second report (Retry) changes nothing
        #expect(box.answers[paths[1]] == ["f1.log"])
        #expect(box.answers[paths[0]] == ["f0.log", "f0.log"])
        #expect(box.answers[paths[7]] == ["error: f7.log: Permission denied"])
        // Asked after the end: answered at once, without downloading again.
        ask(s, paths[250], box)
        #expect(box.answers[paths[250]] == ["f250.log"])
        #expect(box.starts == 1)
        #expect(box.answers.values.reduce(0) { $0 + $1.count } == 202)
    }

    @Test func cancelledDragAnswersEveryItemWithAnError() {
        let box = Box()
        let s = session(["/a", "/b"], box)
        ask(s, "/a", box)
        ask(s, "/b", box)
        box.finish?(([:], "The download was cancelled."))
        #expect(box.answers["/a"] == ["error: The download was cancelled."])
        #expect(box.answers["/b"] == ["error: The download was cancelled."])
    }

    @Test func sessionsMatchOnlyTheirOwnDragBeforeItStarted() {
        let box = Box()
        let s = session(["/a", "/b"], box)
        #expect(s.matches(["/a", "/b"]))
        #expect(!s.matches(["/a"]))
        ask(s, "/a", box)
        #expect(!s.matches(["/a", "/b"]), "a new drag of the same rows is a new download")
    }

    /// Nothing else holds the session (the drag's providers are gone, a new drag replaced it):
    /// it still answers once its download has ended. Before, it was released and the drop
    /// waited for ever — the dragged files never arrived.
    @Test func answersEvenWhenNobodyElseHoldsTheSession() {
        let box = Box()
        weak var weakSession: DragDownloadSession?
        do {
            let s = session(["/srv/a", "/srv/b dir"], box)
            weakSession = s
            ask(s, "/srv/a", box)
            ask(s, "/srv/b dir", box)
        }
        #expect(weakSession != nil, "kept until it has answered")
        box.finish?((["/srv/a": URL(fileURLWithPath: "/tmp/x/a"), "/srv/b dir": URL(fileURLWithPath: "/tmp/x/b dir")], nil))
        box.finish = nil
        #expect(box.answers["/srv/a"] == ["a"])
        #expect(box.answers["/srv/b dir"] == ["b dir"])
        #expect(weakSession == nil, "released once it has answered")
    }
}
