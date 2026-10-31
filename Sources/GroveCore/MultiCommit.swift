import Foundation

extension RebaseStep {
    /// The plan that squashes the selected commits into one: `candidates` (oldest first) must start
    /// with exactly the selected commits; later commits are replayed unchanged. nil otherwise.
    public static func squashing(_ candidates: [RebaseStep], ids: Set<String>) -> [RebaseStep]? {
        guard ids.count >= 2, candidates.count >= ids.count,
              Set(candidates.prefix(ids.count).map(\.id)) == ids else { return nil }
        var steps = candidates
        for i in 1..<ids.count { steps[i].action = .squash }
        steps[0].message = Repository.squashMessage(Array(steps.prefix(ids.count)))
        return steps
    }
}

extension Repository {
    /// Applies `commits` (oldest first) as one cherry-pick sequence: conflicts pause it like any
    /// cherry-pick, and Continue / Skip / Abort work on the whole sequence.
    public func cherryPick(_ commits: [Commit]) async throws {
        let mainline = commits.contains(where: \.isMerge) ? ["-m", "1"] : []
        _ = try await git.run(["cherry-pick"] + mainline + commits.map(\.id), in: root)
    }

    /// Reverts `commits` (newest first, so later changes are undone before the ones they build on).
    public func revert(_ commits: [Commit]) async throws {
        let mainline = commits.contains(where: \.isMerge) ? ["-m", "1"] : []
        _ = try await git.run(["revert", "--no-edit"] + mainline + commits.map(\.id), in: root)
    }

    public struct SquashError: Error, Sendable, CustomStringConvertible {
        public let description: String
    }

    /// Squashes `commits` (any order) into one commit with their combined message. They must be
    /// consecutive commits on the current branch with no merges after them.
    public func squash(_ commits: [Commit]) async throws {
        let ids = Set(commits.map(\.id))
        guard ids.count >= 2 else { throw SquashError(description: "Select at least two commits to squash.") }
        // The oldest selected commit is the one none of the others descends from… i.e. whose
        // parent isn't selected. Exactly one such commit means they form a chain.
        let roots = commits.filter { c in !(c.parents.first.map(ids.contains) ?? false) }
        guard roots.count == 1, let base = roots[0].parents.first else {
            throw SquashError(description: "Only consecutive commits (one after another, not the root commit) can be squashed.")
        }
        let candidates = try await rebaseCandidates(after: base)
        guard let steps = RebaseStep.squashing(candidates, ids: ids) else {
            throw SquashError(description: "The selected commits must be consecutive commits on the current branch.")
        }
        try await interactiveRebase(onto: base, steps: steps)
    }
}
