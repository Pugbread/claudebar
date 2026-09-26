import Foundation

/// Incrementally reads lines appended to a Claude Code transcript (.jsonl).
/// The first read only looks at the last 256 KB, so attaching to a huge session is cheap.
final class TranscriptTail {
    let path: String
    private var offset: UInt64?
    private var carry = Data()
    private var dropFirstLine = false
    private static let initialWindow: UInt64 = 256 * 1024
    private static let maxChunk: UInt64 = 4 * 1024 * 1024

    init(path: String) {
        self.path = path
    }

    func readNewLines() -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }

        if offset == nil {
            let start = size > Self.initialWindow ? size - Self.initialWindow : 0
            offset = start
            dropFirstLine = start > 0
        }
        guard var start = offset else { return [] }
        if size < start {
            // Truncated or replaced: start over.
            start = 0
            carry.removeAll()
            dropFirstLine = false
        }
        guard size > start, (try? handle.seek(toOffset: start)) != nil else {
            offset = start
            return []
        }
        guard let chunk = try? handle.read(upToCount: Int(min(size - start, Self.maxChunk))), !chunk.isEmpty else {
            return []
        }
        offset = start + UInt64(chunk.count)

        var buffer = carry
        buffer.append(chunk)
        var lines: [Data] = []
        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: lineStart..<newline))
            lineStart = buffer.index(after: newline)
        }
        carry = buffer.subdata(in: lineStart..<buffer.endIndex)

        if dropFirstLine, !lines.isEmpty {
            lines.removeFirst()
            dropFirstLine = false
        }
        return lines
    }
}
