import Foundation

public struct RefLabel: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case head, branch, remote, tag }
    public let kind: Kind
    public let name: String
    /// For `.branch`: HEAD points at it. For `.head`: detached HEAD.
    public let isCurrent: Bool

    public init(kind: Kind, name: String, isCurrent: Bool = false) {
        self.kind = kind
        self.name = name
        self.isCurrent = isCurrent
    }
}

public struct Commit: Sendable, Hashable, Identifiable {
    public let id: String
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let date: Date
    public let subject: String
    public let refs: [RefLabel]

    public var shortID: String { String(id.prefix(8)) }
    public var isMerge: Bool { parents.count > 1 }
}

public struct Ref: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case branch, remote, tag }
    public let fullName: String
    public let kind: Kind
    public let name: String
    /// Commit the ref points at (annotated tags are peeled).
    public let target: String
    public let upstream: String?
    /// e.g. "[ahead 1, behind 2]" — empty when in sync.
    public let track: String

    public var id: String { fullName }
}

public struct FileChange: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case ordinary, renamed, unmerged, untracked }
    public let kind: Kind
    public let path: String
    public let origPath: String?
    /// porcelain v2 X (index) and Y (worktree) codes; "." means unchanged.
    public let index: Character
    public let worktree: Character

    public var id: String { path }
    public var isStaged: Bool { (kind == .ordinary || kind == .renamed) && index != "." }
    public var isUnstaged: Bool { kind == .untracked || kind == .unmerged || worktree != "." }
}

/// A file touched by a commit (`--name-status`).
public struct ChangedFile: Sendable, Hashable, Identifiable {
    /// "M", "A", "D", "R100", "C75", "T"…
    public let status: String
    public let path: String
    public let origPath: String?

    public var id: String { path }
    public var letter: Character { status.first ?? "?" }
}

public struct CommitRow: Sendable, Identifiable {
    public let commit: Commit
    public let graph: GraphRow
    public var id: String { commit.id }

    public init(commit: Commit, graph: GraphRow) {
        self.commit = commit
        self.graph = graph
    }
}

public struct Stash: Sendable, Hashable, Identifiable {
    /// "stash@{0}"
    public let name: String
    /// Commit id of the stash entry (stable across pushes / drops of other entries).
    public let id: String
    public let message: String
    public let date: Date
}

/// A multi-step operation git has paused (usually on conflicts).
public enum RepoOperation: Sendable, Hashable {
    case merge(from: String?)
    case rebase(branch: String?, onto: String?, step: Int?, total: Int?)
    case cherryPick
    case revert

    public var name: String {
        switch self {
        case .merge: "merge"
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        }
    }

    public var canSkip: Bool {
        switch self {
        case .merge: false
        default: true
        }
    }
}
