import Foundation

/// A `git bisect` session in progress.
public struct BisectState: Sendable, Hashable {
    public var bad: String?
    public var good: [String]
    public var skipped: [String]
    /// Set once git has narrowed it down ("<sha> is the first bad commit").
    public var culprit: String?
    /// Revisions still to test and roughly how many steps that takes (`rev-list --bisect-vars`).
    public var remaining: Int?
    public var steps: Int?

    public enum Phase: Sendable, Hashable { case needsBad, needsGood, testing, found }
    public var phase: Phase {
        if culprit != nil { return .found }
        if bad == nil { return .needsBad }
        if good.isEmpty { return .needsGood }
        return .testing
    }

    public enum Mark: String, Sendable, CaseIterable { case good, bad, skip }

    /// The mark recorded for `id`, if any.
    public func mark(of id: String) -> Mark? {
        if id == bad { return .bad }
        if good.contains(id) { return .good }
        if skipped.contains(id) { return .skip }
        return nil
    }

    /// "# first bad commit: [sha] subject" in BISECT_LOG.
    static func culprit(fromLog log: String) -> String? {
        for line in log.split(separator: "\n") where line.hasPrefix("# first bad commit: [") {
            let rest = line.dropFirst("# first bad commit: [".count)
            if let end = rest.firstIndex(of: "]") { return String(rest[..<end]) }
        }
        return nil
    }

    /// `git rev-list --bisect-vars` output → (bisect_nr, bisect_steps).
    static func vars(_ text: String) -> (remaining: Int?, steps: Int?) {
        var nr: Int?, steps: Int?
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let v = Int(kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "'")))
            if kv[0] == "bisect_nr" { nr = v } else if kv[0] == "bisect_steps" { steps = v }
        }
        return (nr, steps)
    }
}

extension Repository {
    public nonisolated var isBisecting: Bool {
        FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("BISECT_START").path)
    }

    public nonisolated func bisectState() async -> BisectState? {
        guard isBisecting else { return nil }
        var s = BisectState(bad: nil, good: [], skipped: [])
        let refs = (try? await git.runString(["for-each-ref", "--format=%(refname) %(objectname)", "refs/bisect/"], in: root)) ?? ""
        for line in refs.split(separator: "\n") {
            let p = line.split(separator: " ")
            guard p.count == 2 else { continue }
            let name = p[0], id = String(p[1])
            if name == "refs/bisect/bad" { s.bad = id }
            else if name.hasPrefix("refs/bisect/good-") { s.good.append(id) }
            else if name.hasPrefix("refs/bisect/skip-") { s.skipped.append(id) }
        }
        if let log = try? String(contentsOf: gitDir.appendingPathComponent("BISECT_LOG"), encoding: .utf8) {
            s.culprit = BisectState.culprit(fromLog: log)
        }
        if s.phase == .testing, let bad = s.bad {
            let out = (try? await git.runString(["rev-list", "--bisect-vars", bad, "--not"] + s.good, in: root)) ?? ""
            (s.remaining, s.steps) = BisectState.vars(out)
        }
        return s
    }

    public func bisectStart() async throws {
        _ = try await git.run(["bisect", "start"], in: root)
    }

    /// Marks `rev` (default: the checked-out commit); git then checks out the next one to test.
    public func bisect(_ mark: BisectState.Mark, _ rev: String? = nil) async throws {
        _ = try await git.run(["bisect", mark.rawValue] + (rev.map { [$0] } ?? []), in: root)
    }

    /// Ends the session and returns to where it started.
    public func bisectReset() async throws {
        _ = try await git.run(["bisect", "reset"], in: root)
    }
}
