import Foundation

/// Web URLs for a remote on GitHub, GitLab or Bitbucket (derived from the remote URL; no API).
public struct HostedRepo: Sendable, Hashable {
    public enum Host: String, Sendable { case github = "GitHub", gitlab = "GitLab", bitbucket = "Bitbucket" }
    public let host: Host
    /// e.g. https://github.com/owner/repo
    public let web: URL
    public let remote: String

    /// Parses `git@github.com:o/r.git`, `ssh://git@host:22/o/r.git`, `https://user@host/o/r.git`…
    public init?(remoteURL: String, remote: String = "origin") {
        var s = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var hostName: String
        var path: String
        if let scheme = s.range(of: "://") {
            s = String(s[scheme.upperBound...])
            if let at = s.firstIndex(of: "@"), at < (s.firstIndex(of: "/") ?? s.endIndex) { s = String(s[s.index(after: at)...]) }
            guard let slash = s.firstIndex(of: "/") else { return nil }
            hostName = String(s[..<slash])
            path = String(s[s.index(after: slash)...])
            if let colon = hostName.firstIndex(of: ":") { hostName = String(hostName[..<colon]) }  // port
        } else if let colon = s.firstIndex(of: ":"), !s.hasPrefix("/") {
            // scp-like: [user@]host:path
            var h = String(s[..<colon])
            if let at = h.firstIndex(of: "@") { h = String(h[h.index(after: at)...]) }
            hostName = h
            path = String(s[s.index(after: colon)...])
        } else {
            return nil
        }
        if path.hasSuffix(".git") { path.removeLast(4) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty, path.contains("/") else { return nil }
        let lower = hostName.lowercased()
        let kind: Host
        if lower == "github.com" || lower.hasSuffix(".github.com") || lower.hasPrefix("github.") { kind = .github }
        else if lower.contains("gitlab") { kind = .gitlab }
        else if lower == "bitbucket.org" { kind = .bitbucket }
        else { return nil }
        // ssh.github.com:443 style hosts map to the web host.
        let webHost = lower == "ssh.github.com" ? "github.com" : lower
        guard let url = URL(string: "https://\(webHost)/\(path)") else { return nil }
        host = kind
        web = url
        self.remote = remote
    }

    private func url(_ suffix: String) -> URL {
        URL(string: web.absoluteString + suffix) ?? web
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? s
    }

    private func query(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? s
    }

    public func commit(_ sha: String) -> URL {
        switch host {
        case .github: url("/commit/\(sha)")
        case .gitlab: url("/-/commit/\(sha)")
        case .bitbucket: url("/commits/\(sha)")
        }
    }

    public func branch(_ name: String) -> URL {
        switch host {
        case .github: url("/tree/\(enc(name))")
        case .gitlab: url("/-/tree/\(enc(name))")
        case .bitbucket: url("/src/\(enc(name))")
        }
    }

    public func file(_ path: String, at sha: String) -> URL {
        switch host {
        case .github: url("/blob/\(sha)/\(enc(path))")
        case .gitlab: url("/-/blob/\(sha)/\(enc(path))")
        case .bitbucket: url("/src/\(sha)/\(enc(path))")
        }
    }

    /// New pull / merge request from `branch` (into the default branch unless `base` is given).
    public func newPullRequest(from branch: String, into base: String? = nil) -> URL {
        switch host {
        case .github:
            return base.map { url("/compare/\(enc($0))...\(enc(branch))?expand=1") } ?? url("/pull/new/\(enc(branch))")
        case .gitlab:
            var q = "merge_request%5Bsource_branch%5D=\(query(branch))"
            if let base { q += "&merge_request%5Btarget_branch%5D=\(query(base))" }
            return url("/-/merge_requests/new?\(q)")
        case .bitbucket:
            return url("/pull-requests/new?source=\(query(branch))" + (base.map { "&dest=\(query($0))" } ?? ""))
        }
    }

    /// Open pull / merge requests whose source is `branch`.
    public func pullRequests(for branch: String) -> URL {
        switch host {
        case .github: url("/pulls?q=" + query("is:pr is:open head:\(branch)"))
        case .gitlab: url("/-/merge_requests?state=opened&source_branch=\(query(branch))")
        case .bitbucket: url("/pull-requests?state=OPEN")
        }
    }
}

extension Repository {
    /// The hosted repo for the current branch's upstream remote, else "origin", else the first remote.
    public nonisolated func hostedRepo(preferring remote: String? = nil) async -> HostedRepo? {
        guard let all = try? await remotes(), !all.isEmpty else { return nil }
        let name = [remote, "origin"].compactMap { $0 }.first(where: all.contains) ?? all[0]
        // The configured URL, not `get-url`'s: `url.<base>.insteadOf` rewrites (mirrors, ssh ↔ https)
        // shouldn't hide which host the repository lives on.
        let configured = try? await git.runString(["config", "--get", "remote.\(name).url"], in: root)
        let resolved = configured == nil ? try? await git.runString(["remote", "get-url", name], in: root) : nil
        guard let url = configured ?? resolved else { return nil }
        return HostedRepo(remoteURL: url, remote: name)
    }
}
