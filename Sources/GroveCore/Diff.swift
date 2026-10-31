import Foundation

public struct DiffLine: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case context, added, removed }
    public let kind: Kind
    public let text: String
    /// Followed by "\ No newline at end of file".
    public var noNewline = false
    public let oldNumber: Int?
    public let newNumber: Int?

    public var isChange: Bool { kind != .context }
}

public struct DiffHunk: Sendable, Hashable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    /// Text after the second "@@" (function / section context).
    public let section: String
    public var lines: [DiffLine]

    public var header: String { "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\(section)" }
}

public struct FileDiff: Sendable, Hashable {
    /// "diff --git", "index", "---", "+++" and similar lines, verbatim.
    public var headerLines: [String]
    public var hunks: [DiffHunk]
    public var isBinary: Bool

    public var oldPath: String? { path(prefix: "--- ") }
    public var newPath: String? { path(prefix: "+++ ") }

    private func path(prefix: String) -> String? {
        guard let line = headerLines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let p = String(line.dropFirst(prefix.count))
        if p == "/dev/null" { return nil }
        return p.hasPrefix("a/") || p.hasPrefix("b/") ? String(p.dropFirst(2)) : p
    }

    /// A patch containing one hunk, restricted to `selected` line indexes (nil = whole hunk).
    ///
    /// - Parameter reverse: build it for `git apply --reverse` (unstage / discard). Unselected
    ///   lines are kept as they exist on the side being changed: forward patches turn unselected
    ///   removals into context and drop unselected additions; reverse patches do the opposite.
    public func patch(hunk index: Int, selecting selected: Set<Int>? = nil, reverse: Bool = false) -> String? {
        guard hunks.indices.contains(index) else { return nil }
        let hunk = hunks[index]
        var out: [String] = []
        var oldCount = 0, newCount = 0, changes = 0
        for (i, line) in hunk.lines.enumerated() {
            let picked = selected?.contains(i) ?? true
            var kind: DiffLine.Kind? = line.kind
            if line.kind != .context && !picked {
                // Unselected change: keep what the target side already has.
                let presentInTarget = reverse ? line.kind == .added : line.kind == .removed
                kind = presentInTarget ? .context : nil
            }
            guard let kind else { continue }
            switch kind {
            case .context: out.append(" " + line.text); oldCount += 1; newCount += 1
            case .removed: out.append("-" + line.text); oldCount += 1; changes += 1
            case .added: out.append("+" + line.text); newCount += 1; changes += 1
            }
            if line.noNewline { out.append("\\ No newline at end of file") }
        }
        guard changes > 0 else { return nil }
        let header = "@@ -\(hunk.oldStart),\(oldCount) +\(hunk.newStart),\(newCount) @@\(hunk.section)"
        let fileHeader = headerLines.filter { !$0.hasPrefix("index ") }
        return (fileHeader + [header] + out).joined(separator: "\n") + "\n"
    }
}

public enum DiffParser {
    /// Parses `git diff` output (one or more files).
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var hunk: DiffHunk?
        var oldLine = 0, newLine = 0

        func flushHunk() {
            if let h = hunk { current?.hunks.append(h) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let f = current { files.append(f) }
            current = nil
        }

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for raw in lines {
            if raw.hasPrefix("diff ") {
                flushFile()
                current = FileDiff(headerLines: [raw], hunks: [], isBinary: false)
                continue
            }
            if raw.hasPrefix("@@"), let parsed = parseHeader(raw) {
                if current == nil { current = FileDiff(headerLines: [], hunks: [], isBinary: false) }
                flushHunk()
                hunk = parsed
                oldLine = parsed.oldStart
                newLine = parsed.newStart
                continue
            }
            if hunk != nil {
                switch raw.first {
                case " ":
                    hunk!.lines.append(DiffLine(kind: .context, text: String(raw.dropFirst()), oldNumber: oldLine, newNumber: newLine))
                    oldLine += 1; newLine += 1
                case "+":
                    hunk!.lines.append(DiffLine(kind: .added, text: String(raw.dropFirst()), oldNumber: nil, newNumber: newLine))
                    newLine += 1
                case "-":
                    hunk!.lines.append(DiffLine(kind: .removed, text: String(raw.dropFirst()), oldNumber: oldLine, newNumber: nil))
                    oldLine += 1
                case "\\":
                    if !hunk!.lines.isEmpty { hunk!.lines[hunk!.lines.count - 1].noNewline = true }
                case nil:
                    // Some tools strip the space of empty context lines.
                    hunk!.lines.append(DiffLine(kind: .context, text: "", oldNumber: oldLine, newNumber: newLine))
                    oldLine += 1; newLine += 1
                default:
                    flushHunk()
                    current?.headerLines.append(raw)
                }
                continue
            }
            if current == nil { current = FileDiff(headerLines: [], hunks: [], isBinary: false) }
            current!.headerLines.append(raw)
            if raw.hasPrefix("Binary files ") || raw == "GIT binary patch" { current!.isBinary = true }
        }
        flushFile()
        return files
    }

    static func parseHeader(_ line: String) -> DiffHunk? {
        // @@ -l[,s] +l[,s] @@ section
        let scanner = Scanner(string: line)
        scanner.charactersToBeSkipped = nil
        guard scanner.scanString("@@ -") != nil, let oldStart = scanner.scanInt() else { return nil }
        let oldCount = scanner.scanString(",") != nil ? scanner.scanInt() ?? 1 : 1
        guard scanner.scanString(" +") != nil, let newStart = scanner.scanInt() else { return nil }
        let newCount = scanner.scanString(",") != nil ? scanner.scanInt() ?? 1 : 1
        guard scanner.scanString(" @@") != nil else { return nil }
        let section = String(line[scanner.currentIndex...])
        return DiffHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount, section: section, lines: [])
    }
}
