import Foundation
import CoreGraphics
import Testing
import TetherCore

@Suite struct WindowPlacementTests {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 880)
    let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)

    @Test func usableWindowDoesNotMove() {
        let frame = CGRect(x: -1800, y: -100, width: 900, height: 600)
        #expect(WindowPlacement.fitted(frame, to: [main, left]) == frame)
    }

    @Test func disconnectedDisplayAndPartialIntersectionAreFitted() {
        for frame in [CGRect(x: -1800, y: -100, width: 900, height: 600),
                      CGRect(x: 1439, y: -100, width: 1200, height: 900),
                      CGRect(x: 0, y: 0, width: 3840, height: 2160)] {
            let fitted = WindowPlacement.fitted(frame, to: [main])
            #expect(main.contains(fitted))
            #expect(fitted.width <= frame.width && fitted.height <= frame.height)
        }
    }

    @Test func largestIntersectionWinsAndMissingScreensAreSafe() {
        let frame = CGRect(x: -800, y: 0, width: 1000, height: 600)
        #expect(left.contains(WindowPlacement.fitted(frame, to: [main, left])))
        #expect(WindowPlacement.fitted(frame, to: []) == frame)
    }
}
