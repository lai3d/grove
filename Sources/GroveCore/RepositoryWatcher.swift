import CoreServices
import Foundation

/// Watches a working tree and its git directories with FSEvents and reports
/// coalesced, classified changes.
public final class RepositoryWatcher: @unchecked Sendable {
    public struct Change: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// A file in the working tree changed → status.
        public static let workingTree = Change(rawValue: 1)
        /// The index or an in-progress operation (merge / rebase) changed → status.
        public static let index = Change(rawValue: 2)
        /// HEAD or a ref moved → refs, history.
        public static let refs = Change(rawValue: 4)
        public static let all: Change = [.workingTree, .index, .refs]
    }

    private let root: String
    private let gitDirs: [String]
    private let latency: TimeInterval
    private let handler: @Sendable (Change) -> Void
    private let queue = DispatchQueue(label: "grove.watcher")
    private var stream: FSEventStreamRef?

    public init(root: URL, gitDirs: [URL], latency: TimeInterval = 0.25, handler: @escaping @Sendable (Change) -> Void) {
        self.root = Self.realPath(root.path)
        self.gitDirs = Array(Set(gitDirs.map { Self.realPath($0.path) }))
        self.latency = latency
        self.handler = handler
        queue.setSpecific(key: Self.queueKey, value: true)
    }

    deinit { stop() }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            // Git dirs outside the working tree (linked worktrees, --separate-git-dir) are watched too.
            let paths = [root] + gitDirs.filter { !$0.hasPrefix(root + "/") }
            var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
            let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                               | kFSEventStreamCreateFlagNoDefer)
            guard let s = FSEventStreamCreate(nil, Self.callback, &ctx, paths as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            else { return }
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
    }

    public func stop() {
        let stop = { [self] in
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { stop() } else { queue.sync(execute: stop) }
    }

    private static let queueKey = DispatchSpecificKey<Bool>()

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
        let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        var change: Change = []
        for i in 0..<min(count, list.count) {
            if flags[i] & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                change = .all
                break
            }
            change.formUnion(classify(path: list[i], root: watcher.root, gitDirs: watcher.gitDirs))
        }
        if !change.isEmpty { watcher.handler(change) }
    }

    /// Which parts of the UI a change to `path` invalidates.
    public static func classify(path: String, root: String, gitDirs: [String]) -> Change {
        for dir in gitDirs where path == dir || path.hasPrefix(dir + "/") {
            let rel = path == dir ? "" : String(path.dropFirst(dir.count + 1))
            if rel.hasSuffix(".lock") { return [] }
            if rel == "index" { return .index }
            if rel == "HEAD" || rel == "packed-refs" || rel == "FETCH_HEAD" || rel == "ORIG_HEAD"
                || rel.hasPrefix("refs/") {
                return [.refs, .index]
            }
            if rel == "MERGE_HEAD" || rel == "CHERRY_PICK_HEAD" || rel == "REVERT_HEAD"
                || rel.hasPrefix("rebase-merge") || rel.hasPrefix("rebase-apply") {
                return [.index, .refs]
            }
            return []  // objects/, logs/, hooks, config…
        }
        guard path == root || path.hasPrefix(root + "/") else { return [] }
        // A nested repository's own .git churn is not ours.
        let rel = String(path.dropFirst(root.count))
        if rel.contains("/.git/") || rel.hasSuffix("/.git") { return [] }
        return .workingTree
    }

    static func realPath(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }
}
