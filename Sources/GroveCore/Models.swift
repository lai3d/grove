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

/// One line of an interactive rebase plan.
public struct RebaseStep: Sendable, Hashable, Identifiable {
    public enum Action: String, Sendable, CaseIterable { case pick, reword, squash, fixup, drop }
    public var action: Action
    public let commit: Commit
    /// Full original message.
    public let originalMessage: String
    /// Final message for a reword, or for the head of a squash group (nil = default).
    public var message: String?

    public var id: String { commit.id }

    public init(action: Action = .pick, commit: Commit, originalMessage: String, message: String? = nil) {
        self.action = action
        self.commit = commit
        self.originalMessage = originalMessage
        self.message = message
    }
}

public struct Worktree: Sendable, Hashable, Identifiable {
    public let path: String
    public let head: String?
    /// Short branch name; nil when detached (or bare).
    public let branch: String?
    public let isMain: Bool
    public let isLocked: Bool
    public let isPrunable: Bool
    public var id: String { path }
}

public struct Submodule: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable { case upToDate, notInitialized, differentCommit, conflict }
    public let path: String
    public let commit: String
    public let state: State
    /// `git describe` output git prints in parentheses, if any.
    public let describe: String?
    public var id: String { path }
}

public struct ReflogEntry: Sendable, Hashable, Identifiable {
    /// Position in the reflog (0 = current).
    public let index: Int
    public let commitID: String
    public let date: Date
    /// "commit", "checkout", "reset", "rebase (finish)", "merge feature", "pull"…
    public let action: String
    /// The rest of the reflog subject.
    public let message: String
    public var id: Int { index }
    public var selector: String { "HEAD@{\(index)}" }
}
