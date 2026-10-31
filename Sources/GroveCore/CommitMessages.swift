import Foundation

/// `commit.template` split into what goes into the message box and the `#` guidance lines
/// (shown as a hint instead: `git commit -F` would keep them in the message).
public struct CommitTemplate: Sendable, Hashable {
    public let text: String
    public let hint: String

    public init(_ raw: String) {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        text = lines.filter { !$0.hasPrefix("#") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        hint = lines.filter { $0.hasPrefix("#") }
            .map { String($0.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Repository {
    /// The repository's `commit.template`, if set and readable (relative paths are from the work tree).
    public nonisolated func commitTemplate() async -> CommitTemplate? {
        guard let out = try? await git.runString(["config", "--path", "--get", "commit.template"], in: root) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = CommitTemplate(raw)
        return t.text.isEmpty && t.hint.isEmpty ? nil : t
    }

    /// Recent distinct commit messages on HEAD, newest first (for reuse after a reset or on another branch).
    public nonisolated func recentMessages(limit: Int = 15) async -> [String] {
        guard let out = try? await git.run(["log", "-z", "-n", "\(limit * 3)", "--no-merges", "--format=%B", "HEAD"], in: root) else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for record in out.split(separator: 0) {
            let m = String(decoding: record, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !m.isEmpty, seen.insert(m).inserted else { continue }
            result.append(m)
            if result.count == limit { break }
        }
        return result
    }
}
