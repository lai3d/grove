import Foundation

extension Repository {
    /// `commits` (any order) as one mailbox of `format-patch` patches, oldest first — what `git am` takes.
    public nonisolated func formatPatches(_ commits: [Commit]) async throws -> String {
        // Oldest first: a commit's position in the topological order of the selection.
        let order = try await git.runString(["rev-list", "--topo-order", "--reverse", "--no-walk=sorted"] + commits.map(\.id), in: root)
            .split(separator: "\n").map(String.init)
        var out = ""
        for (i, id) in order.enumerated() {
            var patch = try await git.runString(["format-patch", "--stdout", "-1", id], in: root)
            // Number them like a series ("[PATCH 2/3]"); one `-1` call per commit can't know the total.
            if order.count > 1, let r = patch.range(of: "\nSubject: [PATCH] ") {
                patch.replaceSubrange(r, with: "\nSubject: [PATCH \(i + 1)/\(order.count)] ")
            }
            out += patch
        }
        return out
    }

    public enum PatchKind: Sendable, Equatable { case mailbox, diff }

    /// A `format-patch` mailbox (applied as commits) or a plain diff (applied to the working tree).
    public static func patchKind(_ text: String) -> PatchKind {
        text.hasPrefix("From ") ? .mailbox : .diff
    }

    /// Mailboxes go through `git am --3way` (pauses on conflicts like a rebase); plain diffs through
    /// `git apply --3way`, which falls back to conflict markers instead of refusing.
    public func applyPatch(_ file: URL) async throws {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        switch Self.patchKind(text) {
        case .mailbox: _ = try await git.run(["am", "--3way", file.path], in: root)
        case .diff: _ = try await git.run(["apply", "--3way", file.path], in: root)
        }
    }
}
