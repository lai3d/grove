import Foundation

/// A Git LFS pointer file (what git stores in place of the real content).
public struct LFSPointer: Sendable, Hashable {
    public let oid: String
    public let size: Int64

    /// Parses pointer text: "version https://git-lfs.github.com/spec/v1\noid sha256:…\nsize N".
    public init?(_ text: String) {
        var oid: String?, size: Int64?, version = false
        for line in text.split(separator: "\n") {
            if line.hasPrefix("version https://git-lfs.github.com/spec/") { version = true }
            else if line.hasPrefix("oid sha256:") { oid = String(line.dropFirst("oid sha256:".count)) }
            else if line.hasPrefix("size ") { size = Int64(line.dropFirst(5)) }
        }
        guard version, let oid, let size else { return nil }
        self.oid = oid
        self.size = size
    }

    public init?(_ data: Data) {
        guard data.count < 1024, let s = String(data: data, encoding: .utf8) else { return nil }
        self.init(s)
    }
}

extension FileDiff {
    /// Old / new pointers when this diff is a change of an LFS pointer file; nil otherwise.
    public var lfsChange: (old: LFSPointer?, new: LFSPointer?)? {
        guard !hunks.isEmpty else { return nil }
        let lines = hunks.flatMap(\.lines)
        let old = lines.filter { $0.kind != .added }.map(\.text).joined(separator: "\n")
        let new = lines.filter { $0.kind != .removed }.map(\.text).joined(separator: "\n")
        let o = LFSPointer(old), n = LFSPointer(new)
        guard o != nil || n != nil else { return nil }
        // Every line must belong to a pointer (version / oid / size / ext).
        let pointerish = lines.allSatisfy { l in
            ["version ", "oid ", "size ", "ext-"].contains { l.text.hasPrefix($0) } || l.text.isEmpty
        }
        return pointerish ? (o, n) : nil
    }
}

extension Repository {
    /// True when `.gitattributes` routes anything through the LFS filter.
    public nonisolated var usesLFS: Bool {
        guard let attrs = try? String(contentsOf: root.appendingPathComponent(".gitattributes"), encoding: .utf8) else { return false }
        return attrs.contains("filter=lfs")
    }

    public nonisolated func lfsInstalled() async -> Bool {
        (try? await git.run(["lfs", "version"], in: root)) != nil
    }

    /// Which of `paths` are tracked by LFS (`git check-attr filter`).
    public nonisolated func lfsPaths(_ paths: [String]) async -> Set<String> {
        guard !paths.isEmpty, usesLFS else { return [] }
        guard let out = try? await git.run(["check-attr", "-z", "filter", "--"] + paths, in: root) else { return [] }
        let f = out.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var result = Set<String>()
        var i = 0
        while i + 2 < f.count {
            if f[i + 2] == "lfs" { result.insert(f[i]) }
            i += 3
        }
        return result
    }
}
