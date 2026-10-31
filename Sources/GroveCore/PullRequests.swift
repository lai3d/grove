import Foundation

extension HostedRepo {
    /// The server-side ref holding pull / merge request `number`'s head (nil: host doesn't publish one).
    public func pullRequestRef(_ number: Int) -> String? {
        switch host {
        case .github: "refs/pull/\(number)/head"
        case .gitlab: "refs/merge-requests/\(number)/head"
        case .bitbucket: nil
        }
    }

    /// Local branch a checked-out request goes to: `pr/12` (GitHub) or `mr/12` (GitLab).
    public func pullRequestBranch(_ number: Int) -> String {
        (host == .gitlab ? "mr/" : "pr/") + String(number)
    }

    /// Accepts "123", "#123", "!123" or a pull / merge request URL.
    public static func pullRequestNumber(from input: String) -> Int? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"/(pull|pulls|merge_requests)/\d+"#, options: .regularExpression) {
            s = String(s[r].split(separator: "/").last ?? "")
        }
        if s.hasPrefix("#") || s.hasPrefix("!") { s.removeFirst() }
        guard let n = Int(s), n > 0 else { return nil }
        return n
    }
}

extension Repository {
    /// Fetches `ref` from `remote` into local `branch` and switches to it. An existing branch is only
    /// moved forward (it must not have commits the request lacks), so local work is never dropped.
    public func checkOutRemoteRef(_ ref: String, from remote: String, as branch: String,
                                  progress: @escaping @Sendable (String) -> Void) async throws {
        _ = try await git.runWithProgress(["fetch", "--progress", remote, ref], in: root, progress: progress)
        let fetched = try await git.runString(["rev-parse", "FETCH_HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let exists = (try? await git.run(["rev-parse", "--verify", "-q", "refs/heads/\(branch)"], in: root)) != nil
        if exists {
            let ff = (try? await git.run(["merge-base", "--is-ancestor", "refs/heads/\(branch)", fetched], in: root)) != nil
            guard ff else {
                throw GitError(arguments: ["checkout"], exitCode: 1,
                               stderr: "“\(branch)” has commits that aren't in the request — rename or delete it first")
            }
            if await currentBranch() == branch {
                _ = try await git.run(["merge", "--ff-only", "-q", fetched], in: root)
                return
            }
            _ = try await git.run(["branch", "-f", branch, fetched], in: root)
        } else {
            _ = try await git.run(["branch", branch, fetched], in: root)
        }
        _ = try await git.run(["switch", "-q", branch], in: root)
    }
}

extension HostedRepo {
    /// Web page of pull / merge request `number`.
    public func pullRequest(_ number: Int) -> URL {
        let suffix = switch host {
        case .github: "/pull/\(number)"
        case .gitlab: "/-/merge_requests/\(number)"
        case .bitbucket: "/pull-requests/\(number)"
        }
        return URL(string: web.absoluteString + suffix) ?? web
    }
}
