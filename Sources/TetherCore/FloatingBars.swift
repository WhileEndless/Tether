import Foundation

/// How long bars floating over a terminal stay once nothing happens in them
/// (Settings ▸ Terminal ▸ Floating Bars).
public struct FloatingBarSettings: Codable, Equatable, Sendable {
    /// Seconds without use after which the find bar closes with its highlights (0: it stays).
    public var findBarHideAfter = 20
    /// Seconds a finished upload stays on screen, and a failed one.
    public var uploadDoneHideAfter = 3
    public var uploadFailedHideAfter = 8

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ key: CodingKeys, _ into: inout T) {
            if let v = try? c.decode(T.self, forKey: key) { into = v }
        }
        d(.findBarHideAfter, &findBarHideAfter)
        d(.uploadDoneHideAfter, &uploadDoneHideAfter)
        d(.uploadFailedHideAfter, &uploadFailedHideAfter)
    }
}
