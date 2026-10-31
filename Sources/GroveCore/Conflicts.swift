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

/// State behind the merge editor: which side was picked for each conflict, and the result.
/// Lives in Core so the editor's behaviour is testable without driving the UI.
public struct MergeSession: Sendable, Hashable {
    public enum LoadError: Error, Sendable, Hashable { case notText, noMarkers }

    public let path: String
    public let file: ConflictFile
    public private(set) var choices: [Int: ConflictFile.Choice] = [:]

    public init(path: String, file: ConflictFile) {
        self.path = path
        self.file = file
    }

    /// Parses a conflicted working-tree file's raw bytes.
    public static func load(path: String, data: Data?) -> Result<MergeSession, LoadError> {
        guard let data, let text = String(data: data, encoding: .utf8) else { return .failure(.notText) }
        guard let file = ConflictFile(text) else { return .failure(.noMarkers) }
        return .success(MergeSession(path: path, file: file))
    }

    public var conflictCount: Int { file.conflicts.count }
    public var resolvedCount: Int { choices.count }
    public var isComplete: Bool { resolvedCount == conflictCount }
    public var result: String { file.resolved(choices) }

    public func choice(_ k: Int) -> ConflictFile.Choice? { choices[k] }

    /// Picking the current choice again clears it (the buttons act as a toggle group).
    public mutating func toggle(_ k: Int, _ choice: ConflictFile.Choice) {
        guard file.conflicts.indices.contains(k) else { return }
        if choice == .base && file.conflicts[k].base == nil { return }
        choices[k] = choices[k] == choice ? nil : choice
    }

    /// Applies one choice to every conflict (skipping `.base` where there's no ancestor).
    public mutating func chooseAll(_ choice: ConflictFile.Choice) {
        for k in file.conflicts.indices { if choice != .base || file.conflicts[k].base != nil { choices[k] = choice } }
    }

    public func includesOurs(_ k: Int) -> Bool { [.ours, .oursThenTheirs, .theirsThenOurs].contains(choices[k]) }
    public func includesTheirs(_ k: Int) -> Bool { [.theirs, .oursThenTheirs, .theirsThenOurs].contains(choices[k]) }

    /// Display names: during a rebase "ours" is the upstream being rebased onto, "theirs" your commit.
    public static func sideNames(for operation: RepoOperation?) -> (ours: String, theirs: String) {
        if case .rebase? = operation { return ("Upstream", "Your Commit") }
        return ("Ours", "Theirs")
    }
}
