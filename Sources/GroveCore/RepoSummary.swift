import Foundation

/// At-a-glance state of a repository for the welcome window: one `git status` per repository.
public struct RepoSummary: Sendable, Hashable {
    /// Branch name, or nil when detached.
    public var branch: String?
    public var detachedAt: String?
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    /// Files with staged, unstaged or untracked changes (and conflicts).
    public var changed = 0
    public var conflicts = 0

    /// `git status --porcelain=v2 --branch -z`.
    public init(porcelain data: Data) {
        var skipOriginalPath = false
        for token in data.split(separator: 0) {
            let line = String(decoding: token, as: UTF8.self)
            if skipOriginalPath {  // a rename / copy entry is followed by its original path
                skipOriginalPath = false
                continue
            }
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                branch = head == "(detached)" ? nil : head
            } else if line.hasPrefix("# branch.oid ") {
                detachedAt = String(line.dropFirst("# branch.oid ".count).prefix(8))
            } else if line.hasPrefix("# branch.upstream ") {
                upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if part.hasPrefix("+") { ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if let first = line.first, "12u?".contains(first), line.dropFirst().first == " " {
                changed += 1
                if first == "u" { conflicts += 1 }
                if first == "2" { skipOriginalPath = true }
            }
        }
        if branch != nil { detachedAt = nil }
    }

    public static func load(_ root: URL, git: Git = Git()) async -> RepoSummary? {
        guard let out = try? await git.run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"], in: root)
        else { return nil }
        return RepoSummary(porcelain: out)
    }
}
