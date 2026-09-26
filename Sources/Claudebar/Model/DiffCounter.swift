import Foundation

struct LineDelta: Equatable, Codable {
    var added = 0
    var removed = 0

    var isEmpty: Bool { added == 0 && removed == 0 }

    mutating func add(_ other: LineDelta) {
        added += other.added
        removed += other.removed
    }
}

/// Counts added/removed lines for file-editing tools from a PostToolUse payload.
enum DiffCounter {
    static func delta(tool: String, input: [String: Any], response: Any?) -> LineDelta? {
        let response = response as? [String: Any]

        // Edit/Write responses carry the exact patch Claude Code applied; prefer it.
        if let patch = response?["structuredPatch"] as? [[String: Any]], !patch.isEmpty {
            var delta = LineDelta()
            for hunk in patch {
                for line in hunk["lines"] as? [String] ?? [] {
                    if line.hasPrefix("+") {
                        delta.added += 1
                    } else if line.hasPrefix("-") {
                        delta.removed += 1
                    }
                }
            }
            return delta
        }

        // Codex edits files with apply_patch; its patch says exactly what changed.
        if let patch = patchText(in: input) {
            return patchDelta(patch)
        }

        switch tool {
        case "Edit":
            return diff(input["old_string"] as? String ?? "", input["new_string"] as? String ?? "")
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            return edits.reduce(into: LineDelta()) { total, edit in
                total.add(diff(edit["old_string"] as? String ?? "", edit["new_string"] as? String ?? ""))
            }
        case "Write":
            let content = input["content"] as? String ?? ""
            if let original = response?["originalFile"] as? String {
                return diff(original, content)
            }
            return LineDelta(added: lines(content).count)
        case "NotebookEdit":
            return LineDelta(added: lines(input["new_source"] as? String ?? "").count)
        default:
            return nil
        }
    }

    /// The `*** Begin Patch` text anywhere in a tool's input (key names vary by Codex version).
    static func patchText(in input: [String: Any]) -> String? {
        func search(_ value: Any) -> String? {
            if let text = value as? String { return text.contains("*** Begin Patch") ? text : nil }
            if let array = value as? [Any] { return array.lazy.compactMap(search).first }
            if let object = value as? [String: Any] { return object.values.lazy.compactMap(search).first }
            return nil
        }
        return search(input)
    }

    static func patchDelta(_ patch: String) -> LineDelta {
        var delta = LineDelta()
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("***") || line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") { continue }
            if line.hasPrefix("+") {
                delta.added += 1
            } else if line.hasPrefix("-") {
                delta.removed += 1
            }
        }
        return delta
    }

    /// Paths named by `*** Update File:`, `*** Add File:` and `*** Delete File:` lines.
    static func patchFiles(_ patch: String) -> [String] {
        patch.split(separator: "\n").compactMap { line in
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                return line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    static func diff(_ old: String, _ new: String) -> LineDelta {
        let change = lines(new).difference(from: lines(old))
        return LineDelta(added: change.insertions.count, removed: change.removals.count)
    }

    private static func lines(_ text: String) -> [Substring] {
        var result = text.split(separator: "\n", omittingEmptySubsequences: false)
        if result.last?.isEmpty == true { result.removeLast() }
        return result
    }
}
