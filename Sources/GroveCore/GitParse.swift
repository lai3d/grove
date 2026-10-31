import Foundation

/// Parsers for git's machine-readable output formats.
public enum GitParse {
    static let fieldSeparator: Character = "\u{1f}"

    /// `--format` used with `git log -z`, matched by `commit(_:)`. No `%D`: decorating makes
    /// `git log` up to 3× slower to start on big histories; ref labels come from
    /// `decorations(refs:…)` instead.
    public static let logFormat = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s"

    public static func commit(_ record: Data) -> Commit? {
        let s = String(decoding: record, as: UTF8.self)
        let f = s.split(separator: fieldSeparator, omittingEmptySubsequences: false)
        guard f.count >= 6 else { return nil }
        let id = f[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return Commit(
            id: id,
            parents: f[1].split(separator: " ").map(String.init),
            authorName: String(f[2]),
            authorEmail: String(f[3]),
            date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
            subject: f[5...].joined(separator: String(fieldSeparator))
        )
    }

    private static func strip(_ s: String, _ prefix: String) -> String {
        s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s
    }

    /// Ref labels per commit id, built from `for-each-ref` output (current branch first).
    public static func decorations(refs: [Ref], head: String?, currentBranch: String?) -> [String: [RefLabel]] {
        var out: [String: [RefLabel]] = [:]
        if let head, currentBranch == nil {
            out[head, default: []].append(RefLabel(kind: .head, name: "HEAD", isCurrent: true))
        }
        let order: [Ref.Kind: Int] = [.branch: 0, .remote: 1, .tag: 2]
        for ref in refs.sorted(by: { (order[$0.kind]!, $0.name) < (order[$1.kind]!, $1.name) }) {
            let kind: RefLabel.Kind = switch ref.kind {
            case .branch: .branch
            case .remote: .remote
            case .tag: .tag
            }
            let current = ref.kind == .branch && ref.name == currentBranch
            let label = RefLabel(kind: kind, name: ref.name, isCurrent: current)
            if current { out[ref.target, default: []].insert(label, at: 0) } else { out[ref.target, default: []].append(label) }
        }
        return out
    }

    /// `for-each-ref` format matched by `refs(_:)`.
    public static let refFormat = "--format=%(refname)%1f%(objectname)%1f%(*objectname)%1f%(upstream:short)%1f%(upstream:track)"

    public static func refs(_ data: Data) -> [Ref] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { return nil }
            let full = f[0]
            let kind: Ref.Kind
            let name: String
            if full.hasPrefix("refs/heads/") {
                kind = .branch; name = strip(full, "refs/heads/")
            } else if full.hasPrefix("refs/remotes/") {
                if full.hasSuffix("/HEAD") { return nil }
                kind = .remote; name = strip(full, "refs/remotes/")
            } else if full.hasPrefix("refs/tags/") {
                kind = .tag; name = strip(full, "refs/tags/")
            } else {
                return nil
            }
            return Ref(fullName: full, kind: kind, name: name,
                       target: f[2].isEmpty ? f[1] : f[2],
                       upstream: f[3].isEmpty ? nil : f[3], track: f[4])
        }
    }

    /// `git status --porcelain=v2 -z`.
    public static func status(_ data: Data) -> [FileChange] {
        let tokens = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var out: [FileChange] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            i += 1
            guard let type = t.first else { continue }
            switch type {
            case "1":
                let p = t.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard p.count == 9 else { continue }
                out.append(change(.ordinary, xy: p[1], path: String(p[8]), orig: nil))
            case "2":
                let p = t.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard p.count == 10 else { continue }
                let orig = i < tokens.count ? tokens[i] : nil
                i += 1
                out.append(change(.renamed, xy: p[1], path: String(p[9]), orig: orig))
            case "u":
                let p = t.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard p.count == 11 else { continue }
                out.append(change(.unmerged, xy: p[1], path: String(p[10]), orig: nil))
            case "?":
                out.append(FileChange(kind: .untracked, path: String(t.dropFirst(2)), origPath: nil, index: "?", worktree: "?"))
            default:
                continue  // "#" headers, "!" ignored
            }
        }
        return out
    }

    private static func change(_ kind: FileChange.Kind, xy: Substring, path: String, orig: String?) -> FileChange {
        let chars = Array(xy)
        return FileChange(kind: kind, path: path, origPath: orig,
                          index: chars.first ?? ".", worktree: chars.count > 1 ? chars[1] : ".")
    }

    /// `git diff --name-status -z` / `git diff-tree --name-status -z`.
    public static func nameStatus(_ data: Data) -> [ChangedFile] {
        let tokens = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var out: [ChangedFile] = []
        var i = 0
        while i < tokens.count {
            let status = tokens[i]
            if status.first == "R" || status.first == "C" {
                guard i + 2 < tokens.count else { break }
                out.append(ChangedFile(status: status, path: tokens[i + 2], origPath: tokens[i + 1]))
                i += 3
            } else {
                guard i + 1 < tokens.count else { break }
                out.append(ChangedFile(status: status, path: tokens[i + 1], origPath: nil))
                i += 2
            }
        }
        return out
    }

    /// `git worktree list --porcelain`.
    public static func worktrees(_ text: String) -> [Worktree] {
        var out: [Worktree] = []
        for block in text.components(separatedBy: "\n\n") {
            var path: String?, head: String?, branch: String?
            var locked = false, prunable = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
                else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
                else if line.hasPrefix("locked") { locked = true }
                else if line.hasPrefix("prunable") { prunable = true }
            }
            if let path {
                out.append(Worktree(path: path, head: head, branch: branch, isMain: out.isEmpty, isLocked: locked, isPrunable: prunable))
            }
        }
        return out
    }

    /// `git submodule status`: "<state><sha> <path> (<describe>)".
    public static func submodules(_ text: String) -> [Submodule] {
        text.split(separator: "\n").compactMap { raw in
            guard let flag = raw.first else { return nil }
            let rest = raw.dropFirst()
            let parts = rest.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            var pathPart = String(parts[1])
            var describe: String?
            if pathPart.hasSuffix(")"), let open = pathPart.range(of: " (", options: .backwards) {
                describe = String(pathPart[open.upperBound..<pathPart.index(before: pathPart.endIndex)])
                pathPart = String(pathPart[..<open.lowerBound])
            }
            let state: Submodule.State = switch flag {
            case "-": .notInitialized
            case "+": .differentCommit
            case "U": .conflict
            default: .upToDate
            }
            return Submodule(path: pathPart, commit: String(parts[0]), state: state, describe: describe)
        }
    }
}
