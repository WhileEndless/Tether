import Foundation

/// Semantic version comparison for update checks ("v0.10.1" > "0.9.3").
public enum AppVersion {
    public static func components(_ version: String) -> [Int] {
        let core = version.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
            .split(separator: "-").first ?? ""
        return core.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// True when `candidate` is a higher version than `current`.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
