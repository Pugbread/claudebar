import Foundation

/// The bits of ~/.codex/config.toml that change what a Codex hook event means.
enum CodexConfig {
    private static var cached: (modified: Date, autoReview: Bool)?

    /// True when Codex hands approval requests to its own reviewer (`approvals_reviewer =
    /// "guardian_subagent"`). Its PermissionRequest hook fires before that review, so the
    /// request usually gets decided without you.
    static var autoReviewsApprovals: Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/config.toml")
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
            return false
        }
        if let cached, cached.modified == modified { return cached.autoReview }
        let value = topLevelString("approvals_reviewer", in: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
        let autoReview = value.map { $0 != "user" } ?? false
        cached = (modified, autoReview)
        return autoReview
    }

    /// `key = "value"` before the first [table], i.e. a top-level setting.
    private static func topLevelString(_ key: String, in toml: String) -> String? {
        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            guard line.hasPrefix(key), let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }
}
