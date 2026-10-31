import Foundation
import GroveCore
import Observation

enum SidebarItem: Hashable {
    case workingCopy
    case history
    case ref(String)
    case stash(String)
}

enum BranchSheet: Identifiable {
    case create(startPoint: String, label: String)
    case rename(Ref)

    var id: String {
        switch self {
        case .create(let start, _): "create:\(start)"
        case .rename(let ref): "rename:\(ref.id)"
        }
    }
}

struct ActivityEntry: Identifiable {
    let id: UUID
    let arguments: [String]
    let start: Date
    var exitCode: Int32?
    var duration: TimeInterval?
    var output = ""
    var launchError: String?

    var command: String { "git " + arguments.joined(separator: " ") }
    var isRunning: Bool { exitCode == nil && launchError == nil }
    var succeeded: Bool { exitCode == 0 }
}

struct RemoteOperation {
    let title: String
    var phase = ""
    var fraction: Double?
}

/// A git / ssh prompt waiting for the user; `respond` must be called exactly once.
@MainActor
final class CredentialPrompt: Identifiable {
    nonisolated let request: AskpassServer.Request
    private var reply: ((String?) -> Void)?
    nonisolated var id: UUID { request.id }

    init(request: AskpassServer.Request, reply: @escaping (String?) -> Void) {
        self.request = request
        self.reply = reply
    }

    func respond(_ answer: String?) {
        reply?(answer)
        reply = nil
    }
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
    var selectedStash: Stash? {
        guard case .stash(let id)? = sidebarSelection else { return nil }
        return stashes.first { $0.id == id }
    }

    // History
    private(set) var rows: [CommitRow] = []
    private(set) var rowIndex: [String: Int] = [:]
    /// Bumped whenever `rows` is replaced (not appended), so the table reloads.
    private(set) var logGeneration = 0
    /// Bumped to ask the table to scroll to the selected commit.
    private(set) var scrollToken = 0
    private(set) var isLoadingLog = false

    // History filtering
    var historyFilter = "" {
        didSet { if oldValue != historyFilter { applyFilter() } }
    }
    /// Path-limited history ("Show History of File").
    var pathFilter: String? {
        didSet { if oldValue != pathFilter { reloadLog() } }
    }
    /// Indexes into `rows` that match `historyFilter`; nil = not filtering.
    private(set) var filtered: [Int]?
    private var filteredPosition: [Int: Int] = [:]
    var focusFilterToken = 0
    var isFiltering: Bool { filtered != nil }
    var displayCount: Int { filtered?.count ?? rows.count }

    func displayRow(_ i: Int) -> CommitRow { filtered.map { rows[$0[i]] } ?? rows[i] }

    func displayIndex(of id: String) -> Int? {
        guard let i = rowIndex[id] else { return nil }
        return filtered == nil ? i : filteredPosition[i]
    }
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
    /// Parsed `workingDiff` (first file), for hunk / line actions.
    private(set) var workingFileDiff: FileDiff?
    /// Selected line indexes per hunk in the working diff.
    var selectedLines: [Int: Set<Int>] = [:]
    var pendingDiscardFiles: [ChangeEntry]?

    // Stashes
    private(set) var stashes: [Stash] = []
    private(set) var stashFiles: [ChangedFile] = []
    var selectedStashFileID: ChangedFile.ID? {
        didSet { if oldValue != selectedStashFileID { loadStashDiff() } }
    }
    private(set) var stashDiff = ""
    var showStashSheet = false

    // Commit operations
    var tagSheet: Commit?
    var pendingReset: (commit: Commit, mode: Repository.ResetMode)?
    var pendingDeleteTag: Ref?
    var pendingDropStash: Stash?
    var pendingDiscard: (hunk: Int, lines: Set<Int>?)?
    var selectedEntry: ChangeEntry? { entry(for: selectedChangeID) }
    var commitMessage = ""
    private(set) var isCommitting = false
    var amend = false {
        didSet { if oldValue != amend { amendToggled() } }
    }
    var signOff = UserDefaults.standard.bool(forKey: "signOff") {
        didSet { UserDefaults.standard.set(signOff, forKey: "signOff") }
    }
    private(set) var headIsPushed = false
    private var draftBeforeAmend = ""

    // Branch UI
    var branchSheet: BranchSheet?
    var pendingDelete: Ref?
    var forceDelete: Ref?
    var sidebarFilter = ""
    var expandedGroups: Set<String> = []
    private(set) var isBusy = false

    // Remote operations & activity
    private(set) var remoteOperation: RemoteOperation?
    private var remoteTask: Task<Void, Never>?
    private(set) var activity: [ActivityEntry] = []
    var credentialPrompt: CredentialPrompt?
    var showActivity = false
    var pullMode: Repository.PullMode = Repository.PullMode(rawValue: UserDefaults.standard.string(forKey: "pullMode") ?? "")
        ?? .fastForwardOnly {
        didSet { UserDefaults.standard.set(pullMode.rawValue, forKey: "pullMode") }
    }

    private var logTask: Task<Void, Never>?
    private var logRequest = 0
    @ObservationIgnored private var watcher: RepositoryWatcher?
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
            let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("grove-askpass")
            let askpass = AskpassServer.shared.register(helper: helper) { [weak self] request in
                await withCheckedContinuation { cont in
                    Task { @MainActor in
                        guard let self else { return cont.resume(returning: nil) }
                        self.credentialPrompt?.respond(nil)
                        self.credentialPrompt = CredentialPrompt(request: request) { cont.resume(returning: $0) }
                    }
                }
            }
            let git = Git(environment: askpass, observer: { [weak self] event in
                Task { @MainActor in self?.record(event) }
            })
            let r = try await Repository.open(url, git: git)
            repo = r
            RecentRepositories.add(r.root)
            watcher = r.watch { [weak self] change in
                Task { @MainActor in await self?.filesChanged(change) }
            }
            await refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func refresh() async {
        await refreshRefsAndStatus()
        reloadLog()
    }

    private func filesChanged(_ change: RepositoryWatcher.Change) async {
        if change.contains(.refs) {
            await refresh()
        } else {
            await refreshRefsAndStatus()
        }
    }

    func refreshRefsAndStatus() async {
        guard let repo else { return }
        async let refs = repo.refs()
        async let branch = repo.currentBranch()
        async let status = repo.status()
        async let stashes = repo.stashes()
        do {
            self.stashes = try await stashes
            self.refs = try await refs
            self.currentBranch = await branch
            self.changes = try await status
            let all = stagedEntries + unstagedEntries
            if let id = selectedChangeID, !all.contains(where: { $0.id == id }) {
                // Fully staged / unstaged: follow the file to the other list.
                let flipped = (id.hasPrefix("S:") ? "U:" : "S:") + id.dropFirst(2)
                selectedChangeID = all.contains { $0.id == flipped } ? flipped : nil
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
        // Old rows stay on screen until the first new batch arrives (no flicker on refresh).
        logRequest += 1
        let request = logRequest
        let path = pathFilter
        isLoadingLog = true
        logTask = Task.detached(priority: .userInitiated) { [weak self] in
            let head = await repo.headID()
            // HEAD may not touch `path`, and would then never arrive to claim lane 0.
            var layout = GraphLayout(mainline: path == nil ? head : nil)
            var batch: [CommitRow] = []
            var flushAt = 300  // small first batch: paint fast, then go big
            var first = true
            do {
                for try await record in repo.logRecords(includeHEAD: head != nil, path: path) {
                    guard let c = GitParse.commit(record) else { continue }
                    batch.append(CommitRow(commit: c, graph: layout.add(id: c.id, parents: c.parents)))
                    if batch.count >= flushAt {
                        let b = batch
                        batch.removeAll(keepingCapacity: true)
                        flushAt = 5000
                        await self?.receive(b, request: request, first: first, done: false)
                        first = false
                    }
                }
                await self?.receive(batch, request: request, first: first, done: true)
            } catch is CancellationError {
            } catch {
                await self?.logFailed(error, request: request)
            }
        }
    }

    private func receive(_ batch: [CommitRow], request: Int, first: Bool, done: Bool) {
        guard request == logRequest else { return }
        if first {
            rows = batch
            rowIndex = Dictionary(uniqueKeysWithValues: batch.enumerated().map { ($1.id, $0) })
            if filtered != nil { filtered = []; filteredPosition = [:] }
            extendFilter(from: 0)
            logGeneration += 1
        } else {
            let base = rows.count
            for (i, row) in batch.enumerated() { rowIndex[row.id] = base + i }
            rows.append(contentsOf: batch)
            extendFilter(from: base)
        }
        if first || done, selectedCommitID.map({ rowIndex[$0] == nil }) ?? true {
            // Selection vanished (amend, reset…) or never existed: pick the newest commit.
            if done || selectedCommitID == nil { selectedCommitID = rows.first?.id }
        }
        if done { isLoadingLog = false }
    }

    private func applyFilter() {
        let q = historyFilter.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            filtered = nil
            filteredPosition = [:]
        } else {
            filtered = []
            filteredPosition = [:]
            extendFilter(from: 0)
        }
        logGeneration += 1
        if let id = selectedCommitID, displayIndex(of: id) != nil { scrollToken += 1 }
    }

    private func extendFilter(from start: Int) {
        guard filtered != nil else { return }
        let q = historyFilter.trimmingCharacters(in: .whitespaces)
        let isHex = q.count >= 4 && q.allSatisfy(\.isHexDigit)
        for i in start..<rows.count {
            let c = rows[i].commit
            let hit = c.subject.localizedCaseInsensitiveContains(q)
                || c.authorName.localizedCaseInsensitiveContains(q)
                || c.authorEmail.localizedCaseInsensitiveContains(q)
                || (isHex && c.id.hasPrefix(q.lowercased()))
                || c.refs.contains { $0.name.localizedCaseInsensitiveContains(q) }
            if hit {
                filteredPosition[i] = filtered!.count
                filtered!.append(i)
            }
        }
    }

    func showHistory(of path: String) {
        historyFilter = ""
        pathFilter = path
        sidebarSelection = .history
    }

    private func logFailed(_ error: Error, request: Int) {
        guard request == logRequest else { return }
        isLoadingLog = false
        errorMessage = "\(error)"
    }

    private func sidebarSelectionChanged() {
        switch sidebarSelection {
        case .ref(let id)?:
            if let ref = refs.first(where: { $0.id == id }) { jump(to: ref.target) }
        case .stash?:
            loadStash()
        default:
            break
        }
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
            workingFileDiff = nil
            selectedLines = [:]
            return
        }
        Task { [weak self] in
            let text = (try? await repo.workingDiff(of: e.change, staged: e.staged)) ?? ""
            guard let self, self.selectedChangeID == e.id else { return }
            if text != self.workingDiff { self.selectedLines = [:] }
            self.workingDiff = text
            self.workingFileDiff = DiffParser.parse(text).first
        }
    }

    func stage(_ entries: [ChangeEntry]) async {
        await write { try await $0.stage(entries.map(\.change.path)) }
    }

    func unstage(_ entries: [ChangeEntry]) async {
        await write { try await $0.unstage(entries.map(\.change.path)) }
    }

    var canCommit: Bool {
        !isCommitting && (amend || !stagedEntries.isEmpty)
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func amendToggled() {
        guard let repo else { return }
        if amend {
            draftBeforeAmend = commitMessage
            Task {
                async let message = repo.message(of: "HEAD")
                async let pushed = repo.isHeadPushed()
                let m = (try? await message) ?? ""
                headIsPushed = await pushed
                if amend { commitMessage = m.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        } else {
            commitMessage = draftBeforeAmend
        }
    }

    func commit() async {
        guard canCommit, let repo else { return }
        isCommitting = true
        defer { isCommitting = false }
        do {
            try await repo.commit(message: commitMessage, amend: amend, signOff: signOff)
            draftBeforeAmend = ""
            commitMessage = ""
            amend = false
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

    // MARK: Branches

    func ref(id: String) -> Ref? { refs.first { $0.id == id } }

    func isCurrent(_ ref: Ref) -> Bool { ref.kind == .branch && ref.name == currentBranch }

    func checkout(_ ref: Ref) async {
        guard !isCurrent(ref) else { return }
        await perform { try await $0.checkout(ref) }
    }

    func checkoutDetached(_ commitID: String) async {
        await perform { try await $0.checkoutDetached(commitID) }
    }

    func validateBranchName(_ name: String) async -> String? {
        guard let repo else { return nil }
        if let problem = await repo.validateBranchName(name) { return problem }
        if refs.contains(where: { $0.kind == .branch && $0.name == name }) { return "A branch named “\(name)” already exists" }
        return nil
    }

    /// Returns an error message to show in the sheet, nil on success.
    func createBranch(_ name: String, at startPoint: String, checkout: Bool) async -> String? {
        guard let repo else { return nil }
        do {
            try await repo.createBranch(name, at: startPoint, checkout: checkout)
        } catch {
            return "\(error)"
        }
        await refresh()
        return nil
    }

    func renameBranch(_ ref: Ref, to name: String) async -> String? {
        guard let repo else { return nil }
        do {
            try await repo.renameBranch(ref.name, to: name)
        } catch {
            return "\(error)"
        }
        if case .ref(ref.id)? = sidebarSelection { sidebarSelection = .ref("refs/heads/" + name) }
        await refresh()
        return nil
    }

    func deleteBranch(_ ref: Ref, force: Bool) async {
        guard let repo else { return }
        do {
            try await repo.deleteBranch(ref.name, force: force)
            if case .ref(ref.id)? = sidebarSelection { sidebarSelection = .history }
        } catch let e as GitError where e.isNotFullyMerged && !force {
            forceDelete = ref
        } catch {
            errorMessage = "\(error)"
        }
        await refresh()
    }

    /// Starting point for "New Branch": the selected commit in history, else HEAD.
    func beginNewBranch() {
        if !showsWorkingCopy, let id = selectedCommitID, let row = rowIndex[id] {
            let c = rows[row].commit
            branchSheet = .create(startPoint: c.id, label: "\(c.shortID) “\(c.subject)”")
        } else {
            branchSheet = .create(startPoint: "HEAD", label: currentBranch ?? "HEAD")
        }
    }

    /// Runs a write that can move HEAD or refs, then refreshes everything.
    private func perform(_ op: (Repository) async throws -> Void) async {
        guard let repo, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await op(repo)
        } catch {
            errorMessage = "\(error)"
        }
        await refresh()
    }

    // MARK: Remote operations

    var currentRef: Ref? { refs.first { $0.kind == .branch && $0.name == currentBranch } }
    var hasRemotes: Bool { refs.contains { $0.kind == .remote } }

    func fetch() { runRemote("Fetching") { repo, progress in try await repo.fetch(progress: progress) } }

    func pull(_ mode: Repository.PullMode? = nil) {
        let m = mode ?? pullMode
        runRemote("Pulling") { repo, progress in try await repo.pull(m, progress: progress) }
    }

    func push(force: Bool = false) {
        runRemote(force ? "Force pushing" : "Pushing") { repo, progress in try await repo.push(force: force, progress: progress) }
    }

    func cancelRemoteOperation() { remoteTask?.cancel() }

    private func runRemote(_ title: String, _ op: @escaping @Sendable (Repository, @escaping @Sendable (String) -> Void) async throws -> Void) {
        guard let repo, remoteOperation == nil else { return }
        remoteOperation = RemoteOperation(title: title)
        remoteTask = Task { [weak self] in
            do {
                try await op(repo) { line in
                    Task { @MainActor in self?.progressLine(line) }
                }
            } catch is CancellationError {
            } catch {
                self?.errorMessage = "\(error)"
            }
            self?.remoteOperation = nil
            self?.remoteTask = nil
            await self?.refresh()
        }
    }

    private func progressLine(_ line: String) {
        guard remoteOperation != nil else { return }
        // "Receiving objects:  45% (450/1000), 1.2 MiB | 3 MiB/s"
        if let colon = line.firstIndex(of: ":"), let pct = line.range(of: #"\d{1,3}%"#, options: .regularExpression) {
            remoteOperation?.phase = String(line[..<colon]).replacingOccurrences(of: "remote", with: "").trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            remoteOperation?.fraction = Double(line[pct].dropLast()).map { $0 / 100 }
        } else if !line.hasPrefix(" ") && line.count < 80 {
            remoteOperation?.phase = line
        }
    }

    // MARK: Activity log

    private func record(_ event: GitEvent) {
        guard !event.isReadOnly else { return }
        let i = activity.lastIndex { $0.id == event.id }
        switch event.phase {
        case .started:
            if i == nil { activity.append(ActivityEntry(id: event.id, arguments: event.arguments, start: Date())) }
        case .finished(let code, let duration, let output):
            var e = i.map { activity[$0] } ?? ActivityEntry(id: event.id, arguments: event.arguments, start: Date())
            e.exitCode = code
            e.duration = duration
            e.output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i { activity[i] = e } else { activity.append(e) }
        case .failedToLaunch(let message):
            var e = i.map { activity[$0] } ?? ActivityEntry(id: event.id, arguments: event.arguments, start: Date())
            e.launchError = message
            if let i { activity[i] = e } else { activity.append(e) }
        }
        if activity.count > 500 { activity.removeFirst(activity.count - 500) }
    }

    func clearActivity() { activity.removeAll { !$0.isRunning } }

    // MARK: Hunks

    func applyHunk(_ action: Repository.HunkAction, hunk: Int, lines: Set<Int>?) async {
        guard let diff = workingFileDiff else { return }
        await write { try await $0.apply(action, hunk: hunk, lines: lines, in: diff) }
        selectedLines = [:]
    }

    // MARK: Discard & stash

    func discard(_ entries: [ChangeEntry]) async {
        await write { try await $0.discard(entries.map(\.change)) }
    }

    func stashChanges(message: String, includeUntracked: Bool) async -> String? {
        guard let repo else { return nil }
        do {
            try await repo.stash(message: message, includeUntracked: includeUntracked)
        } catch {
            return "\(error)"
        }
        await refreshRefsAndStatus()
        return nil
    }

    func applyStash(_ stash: Stash, pop: Bool) async {
        await write { try await $0.applyStash(stash, pop: pop) }
        if pop { sidebarSelection = .workingCopy }
    }

    func dropStash(_ stash: Stash) async {
        await write { try await $0.dropStash(stash) }
        if selectedStash == nil, case .stash? = sidebarSelection { sidebarSelection = .history }
    }

    private func loadStash() {
        guard let repo, let stash = selectedStash else { return }
        stashFiles = []
        stashDiff = ""
        Task { [weak self] in
            let files = (try? await repo.stashFiles(stash)) ?? []
            guard let self, self.selectedStash?.id == stash.id else { return }
            self.stashFiles = files
            self.selectedStashFileID = files.first?.id
            self.loadStashDiff()
        }
    }

    private func loadStashDiff() {
        guard let repo, let stash = selectedStash, let id = selectedStashFileID,
              let file = stashFiles.first(where: { $0.id == id }) else {
            stashDiff = ""
            return
        }
        Task { [weak self] in
            let text = (try? await repo.stashDiff(stash, file: file)) ?? ""
            guard let self, self.selectedStashFileID == id else { return }
            self.stashDiff = text
        }
    }

    // MARK: Commit operations

    func cherryPick(_ commit: Commit) async { await perform { try await $0.cherryPick(commit) } }

    func revert(_ commit: Commit) async { await perform { try await $0.revert(commit) } }

    func reset(_ mode: Repository.ResetMode, to commit: Commit) async {
        await perform { try await $0.reset(mode, to: commit.id) }
    }

    func validateTagName(_ name: String) async -> String? {
        guard let repo else { return nil }
        if let problem = await repo.validateTagName(name) { return problem }
        if refs.contains(where: { $0.kind == .tag && $0.name == name }) { return "Tag “\(name)” already exists" }
        return nil
    }

    func createTag(_ name: String, at commit: Commit, message: String) async -> String? {
        guard let repo else { return nil }
        do {
            try await repo.createTag(name, at: commit.id, message: message)
        } catch {
            return "\(error)"
        }
        await refresh()
        return nil
    }

    func deleteTag(_ ref: Ref) async {
        await perform { try await $0.deleteTag(ref.name) }
        if case .ref(ref.id)? = sidebarSelection { sidebarSelection = .history }
    }
}
