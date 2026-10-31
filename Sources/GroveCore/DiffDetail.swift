import Foundation

/// Intra-line (word-level) changes between a removed and an added line.
public enum WordDiff {
    /// Changed ranges, in UTF-16 offsets, of `old` and `new`. Empty when the lines are
    /// too different for highlighting to help (less than ~30% in common).
    public static func ranges(old: String, new: String) -> (old: [NSRange], new: [NSRange]) {
        let a = tokens(old), b = tokens(new)
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= 250_000 else { return ([], []) }
        // LCS table over tokens.
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i].text == b[j].text ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var keepA = Array(repeating: false, count: a.count), keepB = Array(repeating: false, count: b.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i].text == b[j].text {
                keepA[i] = true; keepB[j] = true; i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        let common = a.indices.filter { keepA[$0] }.reduce(0) { $0 + a[$1].range.length }
        let total = max(old.utf16.count, new.utf16.count)
        guard total > 0, Double(common) / Double(total) >= 0.3 else { return ([], []) }
        return (merge(a, keepA), merge(b, keepB))
    }

    struct Token { let text: Substring; let range: NSRange }

    /// Words, runs of whitespace, and single punctuation characters.
    static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var start = s.startIndex
        var offset = 0
        func kind(_ c: Character) -> Int { c.isLetter || c.isNumber || c == "_" ? 0 : (c.isWhitespace ? 1 : 2) }
        while start < s.endIndex {
            let k = kind(s[start])
            var end = s.index(after: start)
            if k != 2 { while end < s.endIndex && kind(s[end]) == k { end = s.index(after: end) } }
            let text = s[start..<end]
            let len = text.utf16.count
            out.append(Token(text: text, range: NSRange(location: offset, length: len)))
            offset += len
            start = end
        }
        return out
    }

    /// Coalesces adjacent changed tokens into ranges.
    private static func merge(_ tokens: [Token], _ keep: [Bool]) -> [NSRange] {
        var out: [NSRange] = []
        for (t, kept) in zip(tokens, keep) where !kept {
            if let last = out.last, NSMaxRange(last) == t.range.location {
                out[out.count - 1] = NSRange(location: last.location, length: last.length + t.range.length)
            } else {
                out.append(t.range)
            }
        }
        return out
    }
}

/// Side-by-side rows for a hunk: context on both sides, removals paired with additions.
public struct SplitRow: Sendable, Hashable {
    public let left: DiffLine?
    public let right: DiffLine?
    /// Indexes into the hunk's lines (for selection / word diff lookups).
    public let leftIndex: Int?
    public let rightIndex: Int?
}

extension DiffHunk {
    public var splitRows: [SplitRow] {
        var rows: [SplitRow] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.kind == .context {
                rows.append(SplitRow(left: line, right: line, leftIndex: i, rightIndex: i))
                i += 1
                continue
            }
            var removed: [Int] = [], added: [Int] = []
            while i < lines.count, lines[i].kind == .removed { removed.append(i); i += 1 }
            while i < lines.count, lines[i].kind == .added { added.append(i); i += 1 }
            for k in 0..<max(removed.count, added.count) {
                let l = k < removed.count ? removed[k] : nil
                let r = k < added.count ? added[k] : nil
                rows.append(SplitRow(left: l.map { lines[$0] }, right: r.map { lines[$0] }, leftIndex: l, rightIndex: r))
            }
        }
        return rows
    }

    /// For each changed line index, the index of its counterpart (i-th removal ↔ i-th addition in a block).
    public var pairs: [Int: Int] {
        var out: [Int: Int] = [:]
        for row in splitRows {
            if let l = row.leftIndex, let r = row.rightIndex, l != r {
                out[l] = r
                out[r] = l
            }
        }
        return out
    }
}
