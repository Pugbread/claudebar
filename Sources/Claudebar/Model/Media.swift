import CryptoKit
import Foundation

/// An image or video an agent touched, for the shelf at the top of the panel.
struct MediaItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case image, video }

    let path: String
    let kind: Kind
    var seenAt: Date
    var agent: Agent
    var session: String
    /// What happened to it: "made", "opened", or the tool that returned it.
    var action: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

/// Finds the media files in a finished tool call.
enum MediaScanner {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Where images that tools return inline (screenshots, renders) are saved so they can be shown.
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claudebar/media", isDirectory: true)
    }

    private static let ignoredPathParts = ["/node_modules/", "/.git/", "/DerivedData/", "/.build/", ".app/Contents/"]
    /// Bodies of code being written: a path merely mentioned in source isn't something the agent touched.
    private static let ignoredKeys: Set<String> = ["content", "new_string", "old_string", "edits", "new_source"]

    private static let extensionPattern = imageExtensions.union(videoExtensions).sorted().joined(separator: "|")
    private static let quotedPath = try! NSRegularExpression(
        pattern: #"["'`]([^"'`\n]{1,400}?\.(?:\#(extensionPattern)))["'`]"#, options: .caseInsensitive)
    private static let barePath = try! NSRegularExpression(
        pattern: #"(?:file://)?[~\w./@%+\-]*[\w\-]\.(?:\#(extensionPattern))\b"#, options: .caseInsensitive)

    static func kind(of path: String) -> MediaItem.Kind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    /// Media files a finished tool call touched: the file it read or wrote, paths in the command
    /// it ran, and, for MCP tools (which often save what they generate), paths it reported back.
    /// Only files that exist count.
    static func files(tool: String, input: [String: Any], response: Any?, cwd: String) -> [String] {
        var texts: [String] = []
        switch tool {
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "view_image":
            texts = ["file_path", "notebook_path", "path"].compactMap { input[$0] as? String }
        case "Bash", "exec_command", "shell", "local_shell", "exec":
            for key in ["command", "cmd", "input", "code"] {
                if let text = input[key] as? String { texts.append(text) }
                if let argv = input[key] as? [String] { texts.append(argv.joined(separator: " ")) }
            }
        case "apply_patch":
            texts = DiffCounter.patchText(in: input).map(DiffCounter.patchFiles) ?? []
        default:
            collectStrings(input, into: &texts)
            if tool.hasPrefix("mcp__"), let response { collectStrings(response, into: &texts) }
        }

        var seen = Set<String>()
        return texts.flatMap(candidates).compactMap { resolve($0, cwd: cwd) }.filter { path in
            kind(of: path) != nil && isUsable(path) && seen.insert(path).inserted
        }
    }

    /// Images a tool returned inline, as MCP image blocks, decoded.
    static func inlineImages(in response: Any?) -> [Data] {
        var found: [Data] = []
        func visit(_ value: Any) {
            if let array = value as? [Any] {
                array.forEach(visit)
                return
            }
            guard let object = value as? [String: Any] else { return }
            if object["type"] as? String == "image" {
                let source = object["source"] as? [String: Any]
                if let base64 = (object["data"] as? String) ?? (source?["data"] as? String),
                   let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), data.count > 64 {
                    found.append(data)
                }
                return
            }
            object.values.forEach(visit)
        }
        if let response { visit(response) }
        return found
    }

    /// Saves inline image bytes to the cache, named by their content so repeats don't pile up.
    static func cache(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        let ext: String
        if bytes.starts(with: [0xFF, 0xD8]) {
            ext = "jpg"
        } else if bytes.starts(with: [0x47, 0x49, 0x46]) {
            ext = "gif"
        } else if bytes.count >= 12, bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            ext = "webp"
        } else {
            ext = "png"
        }
        let name = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let url = cacheDirectory.appendingPathComponent("\(name).\(ext)")
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                return nil
            }
        }
        return url.path
    }

    /// Images Codex generated for a session since `date` (it saves them per session).
    static func codexGenerated(sessionID: String, since date: Date) -> [String] {
        let folder = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/generated_images/\(sessionID)", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        return files.filter { url in
            kind(of: url.path) != nil
                && ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) > date
        }.map(\.path)
    }

    static func modificationDate(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: - Helpers

    private static func collectStrings(_ value: Any, into texts: inout [String]) {
        if let text = value as? String {
            if text.count <= 20_000 { texts.append(text) }
        } else if let array = value as? [Any] {
            array.forEach { collectStrings($0, into: &texts) }
        } else if let object = value as? [String: Any] {
            for (key, child) in object where !ignoredKeys.contains(key) {
                collectStrings(child, into: &texts)
            }
        }
    }

    private static func candidates(in text: String) -> [String] {
        let text = String(text.prefix(200_000))
        let range = NSRange(text.startIndex..., in: text)
        var found = quotedPath.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
        found += barePath.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
        return found
    }

    private static func resolve(_ raw: String, cwd: String) -> String? {
        var path = raw.hasPrefix("file://") ? String(raw.dropFirst(7)) : raw
        if path.hasPrefix("~") { path = NSHomeDirectory() + path.dropFirst() }
        if !path.hasPrefix("/") {
            guard !cwd.isEmpty else { return nil }
            path = cwd + "/" + path
        }
        return (path as NSString).standardizingPath
    }

    private static func isUsable(_ path: String) -> Bool {
        guard !ignoredPathParts.contains(where: path.contains),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0
    }
}
