import SwiftUI

enum Palette {
    static let coral = Color(red: 0.95, green: 0.56, blue: 0.40)
    static let orange = Color(red: 1.00, green: 0.52, blue: 0.22)
    static let butter = Color(red: 1.00, green: 0.90, blue: 0.55)
    static let violet = Color(red: 0.69, green: 0.57, blue: 1.00)
    static let pink = Color(red: 0.98, green: 0.47, blue: 0.74)
    static let sky = Color(red: 0.42, green: 0.69, blue: 1.00)
    static let mint = Color(red: 0.32, green: 0.89, blue: 0.68)
    static let cyan = Color(red: 0.38, green: 0.86, blue: 0.96)
    static let amber = Color(red: 1.00, green: 0.77, blue: 0.29)
    static let green = Color(red: 0.38, green: 0.91, blue: 0.53)
    static let red = Color(red: 1.00, green: 0.43, blue: 0.43)
    static let indigo = Color(red: 0.52, green: 0.55, blue: 1.00)
    // Codex's cloud: lavender on top, cornflower through the middle, deep blue below.
    static let codex = Color(red: 0.49, green: 0.60, blue: 1.00)
    static let codexLavender = Color(red: 0.72, green: 0.64, blue: 1.00)
    static let codexDeep = Color(red: 0.26, green: 0.27, blue: 1.00)
    static let slate = Color(white: 0.62)

    static let add = Color(red: 0.38, green: 0.91, blue: 0.53)
    static let remove = Color(red: 1.00, green: 0.43, blue: 0.43)

    static let text = Color.white.opacity(0.93)
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.32)
    static let card = Color.white.opacity(0.055)
}

enum Fmt {
    /// 7:23, 1:02:09
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// 0.4s, 12s, 3m 4s, 1h 2m
    static func short(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.1fs", max(0, seconds)) }
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    /// 38m, 2h 14m
    static func hours(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    /// 982, 12.4k, 142k, 1.20M
    static func tokens(_ value: Int) -> String {
        switch value {
        case ..<1000: "\(value)"
        case ..<10_000: String(format: "%.1fk", Double(value) / 1000)
        case ..<1_000_000: "\(value / 1000)k"
        default: String(format: "%.2fM", Double(value) / 1_000_000)
        }
    }

    /// claude-opus-5-5 → Opus 5.5, claude-haiku-4-5-20251001 → Haiku 4.5
    static func model(_ id: String?) -> String? {
        guard var name = id?.lowercased(), !name.isEmpty else { return nil }
        let longContext = name.contains("[1m]")
        name = name.replacingOccurrences(of: "[1m]", with: "")
        if name.hasPrefix("gpt-") {
            // gpt-5.5-codex → GPT-5.5 Codex
            var parts = name.split(separator: "-").map(String.init)
            parts.removeFirst()
            let version = parts.prefix { $0.first?.isNumber == true }
            let suffix = parts.dropFirst(version.count).map(\.capitalized)
            return (["GPT-" + version.joined(separator: "-")] + suffix).joined(separator: " ")
        }
        if name.hasPrefix("claude-") { name.removeFirst(7) }
        var parts = name.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return nil }
        let version = parts.dropFirst().joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " \(version)") + (longContext ? " 1M" : "")
    }

    static func truncate(_ text: String, _ limit: Int, middle: Bool = false) -> String {
        guard text.count > limit, limit > 3 else { return text }
        guard middle else { return String(text.prefix(limit - 1)) + "…" }
        let head = (limit - 1) / 2
        return String(text.prefix(head)) + "…" + String(text.suffix(limit - 1 - head))
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}
