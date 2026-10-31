import Foundation
import GroveCore
import Observation

enum SidebarItem: Hashable {
    case workingCopy
    case history
    case ref(String)
}

struct CommitDetail {
    let commit: Commit
    let message: String
    let files: [ChangedFile]
}

struct ChangeEntry: Identifiable, Hashable {
    let change: FileChange
    let staged: Bool
    var id: String { (staged ? "S:" : "U:") + change.path }
    var letter: String {
        switch change.kind {
        case .untracked: "?"
        case .unmerged: "U"
        default: String(staged ? change.index : change.worktree)
        }
    }
}

@MainActor
@Observable
final class RepoModel {
    let url: URL
    private(set) var repo: Repository?
    var errorMessage: String?

    var sidebarSelection: SidebarItem? = .history {
        didSet { sidebarSelectionChanged() }
    }
    var showsWorkingCopy: Bool { sidebarSelection == .workingCopy }

    // History
    private(set) var rows: [CommitRow] = []
    private(set) var rowIndex: [String: Int] = [:]
    /// Bumped whenever `rows` is replaced (not appended), so the table reloads.
    private(set) var logGeneration = 0
    /// Bumped to ask the table to scroll to the selected commit.
    private(set) var scrollToken = 0
    private(set) var isLoadingLog = false
    private(set) var refs: [Ref] = []
    private(set) var currentBranch: String?

    var selectedCommitID: String? {
        didSet { if oldValue != selectedCommitID { loadCommitDetail() } }
    }
    private(set) var detail: CommitDetail?
    var selectedFileID: ChangedFile.ID? {
        didSet { if oldValue != selectedFileID { loadCommitFileDiff() } }
    }
    private(set) var commitDiff = ""

    // Working copy
    private(set) var changes: [FileChange] = []
    var selectedChangeID: ChangeEntry.ID? {
        didSet { if oldValue != selectedChangeID { loadWorkingDiff() } }
    }
    private(set) var workingDiff = ""
    var commitMessage = ""
    private(set) var isCommitting = false

    private var logTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    var title: String { repo?.name ?? url.lastPathComponent }
    var stagedEntries: [ChangeEntry] { changes.filter(\.isStaged).map { ChangeEntry(change: $0, staged: true) } }
    var unstagedEntries: [ChangeEntry] { changes.filter(\.isUnstaged).map { ChangeEntry(change: $0, staged: false) } }

    func load() async {
        guard repo == nil else { return }
        do {
            let r = try await Repository.open(url)
            repo = r
            RecentRepositories.add(r.root)
            await refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func refresh() async {
        await refreshRefsAndStatus()
        reloadLog()
    }

    func refreshRefsAndStatus() async {
        guard let repo else { return }
        async let refs = repo.refs()
        async let branch = repo.currentBranch()
        async let status = repo.status()
        do {
            self.refs = try await refs
            self.currentBranch = await branch
            self.changes = try await status
            if let id = selectedChangeID, !(stagedEntries + unstagedEntries).contains(where: { $0.id == id }) {
                selectedChangeID = nil
            } else {
                loadWorkingDiff()
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    // MARK: History

    private func reloadLog() {
        guard let repo else { return }
        logTask?.cancel()
        let previousSelection = selectedCommitID
        rows = []
        rowIndex = [:]
        logGeneration += 1
        isLoadingLog = true
        let generation = logGeneration
        logTask = Task.detached(priority: .userInitiated) { [weak self] in
            let head = await repo.headID()
            var layout = GraphLayout(mainline: head)
            var batch: [CommitRow] = []
            var flushAt = 300  // small first batch: paint fast, then go big
            do {
                for try await record in repo.logRecords(includeHEAD: head != nil) {
                    guard let c = GitParse.commit(record) else { continue }
                    batch.append(CommitRow(commit: c, graph: layout.add(id: c.id, parents: c.parents)))
                    if batch.count >= flushAt {
                        let b = batch
                        batch.removeAll(keepingCapacity: true)
                        flushAt = 5000
                        await self?.append(b, generation: generation, restoring: previousSelection)
                    }
                }
                await self?.append(batch, generation: generation, restoring: previousSelection, done: true)
            } catch is CancellationError {
            } catch {
                await self?.logFailed(error, generation: generation)
            }
        }
    }

    private func append(_ batch: [CommitRow], generation: Int, restoring previous: String?, done: Bool = false) {
        guard generation == logGeneration else { return }
        let base = rows.count
        for (i, row) in batch.enumerated() { rowIndex[row.id] = base + i }
        rows.append(contentsOf: batch)
        if selectedCommitID == nil || base == 0 {
            if let previous, rowIndex[previous] != nil {
                selectedCommitID = previous
                if base == 0 { loadCommitDetail() }
            } else if base == 0 {
                selectedCommitID = rows.first?.id
            }
        }
        if done { isLoadingLog = false }
    }

    private func logFailed(_ error: Error, generation: Int) {
        guard generation == logGeneration else { return }
        isLoadingLog = false
        errorMessage = "\(error)"
    }

    private func sidebarSelectionChanged() {
        guard case .ref(let id)? = sidebarSelection, let ref = refs.first(where: { $0.id == id }) else { return }
        jump(to: ref.target)
    }

    func jump(to commitID: String) {
        guard rowIndex[commitID] != nil else { return }
        selectedCommitID = commitID
        scrollToken += 1
    }

    private func loadCommitDetail() {
        detailTask?.cancel()
        guard let repo, let id = selectedCommitID, let idx = rowIndex[id] else {
            detail = nil
            selectedFileID = nil
            return
        }
        let commit = rows[idx].commit
        detailTask = Task { [weak self] in
            do {
                async let message = repo.message(of: commit.id)
                async let files = repo.changedFiles(in: commit)
                let d = CommitDetail(commit: commit, message: try await message, files: try await files)
                guard let self, !Task.isCancelled, self.selectedCommitID == commit.id else { return }
                self.detail = d
                self.selectedFileID = d.files.first?.id
                self.loadCommitFileDiff()
            } catch {
                if !Task.isCancelled { self?.errorMessage = "\(error)" }
            }
        }
    }

    private func loadCommitFileDiff() {
        diffTask?.cancel()
        guard let repo, let detail, let id = selectedFileID,
              let file = detail.files.first(where: { $0.id == id }) else {
            commitDiff = ""
            return
        }
        diffTask = Task { [weak self] in
            let text = (try? await repo.diff(of: file, in: detail.commit)) ?? ""
            guard let self, !Task.isCancelled else { return }
            self.commitDiff = text
        }
    }

    // MARK: Working copy

    private func entry(for id: ChangeEntry.ID?) -> ChangeEntry? {
        guard let id else { return nil }
        return (stagedEntries + unstagedEntries).first { $0.id == id }
    }

    private func loadWorkingDiff() {
        guard let repo, let e = entry(for: selectedChangeID) else {
            workingDiff = ""
            return
        }
        Task { [weak self] in
            let text = (try? await repo.workingDiff(of: e.change, staged: e.staged)) ?? ""
            guard let self, self.selectedChangeID == e.id else { return }
            self.workingDiff = text
        }
    }

    func stage(_ entries: [ChangeEntry]) async {
        await write { try await $0.stage(entries.map(\.change.path)) }
    }

    func unstage(_ entries: [ChangeEntry]) async {
        await write { try await $0.unstage(entries.map(\.change.path)) }
    }

    var canCommit: Bool {
        !isCommitting && !stagedEntries.isEmpty && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func commit() async {
        guard canCommit, let repo else { return }
        isCommitting = true
        defer { isCommitting = false }
        do {
            try await repo.commit(message: commitMessage)
            commitMessage = ""
            selectedCommitID = nil
            await refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func write(_ op: (Repository) async throws -> Void) async {
        guard let repo else { return }
        do {
            try await op(repo)
        } catch {
            errorMessage = "\(error)"
        }
        await refreshRefsAndStatus()
    }
}
