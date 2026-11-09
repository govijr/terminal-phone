import ActivityKit
import Foundation

/// Shared between the app and the widget extension: the Live Activity's data.
struct ImportAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var count: Int
        var currentYear: Int
        var finished: Bool
    }
    /// Newest first, for example [2026, 2025, ..., 2019].
    var years: [Int]
}

enum ImportFormat {
    static func count(_ value: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
