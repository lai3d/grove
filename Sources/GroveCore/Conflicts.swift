import Foundation

/// A text file with conflict markers, split into plain text and conflict regions.
public struct ConflictFile: Sendable, Hashable {
    public struct Conflict: Sendable, Hashable {
        public let ours: [String]
        /// Only with `merge.conflictStyle = diff3 / zdiff3`.
        public let base: [String]?
        public let theirs: [String]
        public let oursLabel: String
        public let theirsLabel: String
    }

    public enum Segment: Sendable, Hashable {
        case text([String])
        case conflict(Conflict)
    }

    public enum Choice: Sendable, Hashable, CaseIterable {
        case ours, theirs, oursThenTheirs, theirsThenOurs, base
    }

    public let segments: [Segment]
    let trailingNewline: Bool

    public var conflicts: [Conflict] {
        segments.compactMap { if case .conflict(let c) = $0 { c } else { nil } }
    }

    /// nil when there are no (well-formed) conflict markers.
    public init?(_ text: String) {
        var lines = text.components(separatedBy: "\n")
        trailingNewline = lines.last == ""
        if trailingNewline { lines.removeLast() }
        var segments: [Segment] = []
        var plain: [String] = []
        var i = 0
        func flush() {
            if !plain.isEmpty { segments.append(.text(plain)); plain = [] }
        }
        while i < lines.count {
            let line = lines[i]
            guard line.hasPrefix("<<<<<<<") else {
                plain.append(line)
                i += 1
                continue
            }
            let oursLabel = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            var ours: [String] = [], base: [String]? = nil, theirs: [String] = []
            var section = 0  // 0 ours, 1 base, 2 theirs
            var j = i + 1
            var theirsLabel = ""
            var closed = false
            while j < lines.count {
                let l = lines[j]
                if section == 0 && l.hasPrefix("|||||||") { section = 1; base = [] }
                else if section < 2 && l == "=======" { section = 2 }
                else if section == 2 && l.hasPrefix(">>>>>>>") {
                    theirsLabel = String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    closed = true
                    break
                } else {
                    switch section {
                    case 0: ours.append(l)
                    case 1: base!.append(l)
                    default: theirs.append(l)
                    }
                }
                j += 1
            }
            guard closed else { return nil }
            flush()
            segments.append(.conflict(Conflict(ours: ours, base: base, theirs: theirs, oursLabel: oursLabel, theirsLabel: theirsLabel)))
            i = j + 1
        }
        flush()
        guard segments.contains(where: { if case .conflict = $0 { true } else { false } }) else { return nil }
        self.segments = segments
    }

    /// The file with conflict `k` replaced according to `choices[k]`; unresolved conflicts keep their markers.
    public func resolved(_ choices: [Int: Choice]) -> String {
        var out: [String] = []
        var k = 0
        for seg in segments {
            switch seg {
            case .text(let lines):
                out += lines
            case .conflict(let c):
                defer { k += 1 }
                switch choices[k] {
                case .ours?: out += c.ours
                case .theirs?: out += c.theirs
                case .oursThenTheirs?: out += c.ours + c.theirs
                case .theirsThenOurs?: out += c.theirs + c.ours
                case .base?: out += c.base ?? []
                case nil:
                    out.append("<<<<<<< " + c.oursLabel)
                    out += c.ours
                    if let b = c.base { out.append("|||||||"); out += b }
                    out.append("=======")
                    out += c.theirs
                    out.append(">>>>>>> " + c.theirsLabel)
                }
            }
        }
        return out.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }
}

extension Repository {
    /// Writes a resolved file and stages it (marks the conflict resolved).
    public func saveResolution(_ path: String, text: String) async throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        try await markResolved(path)
    }
}
