import AppKit
import GroveCore
import SwiftUI

struct RootView: View {
    @Binding var url: URL?

    var body: some View {
        if let url {
            RepoWindow(url: url).id(url)
        } else {
            WelcomeView { url = $0 }
                .onAppear { if let launch = LaunchOptions.take() { url = launch } }
        }
    }
}

struct WelcomeView: View {
    let open: (URL) -> Void
    @State private var recents = RecentRepositories.all()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(systemName: "tree")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.green.gradient)
                Text("Grove").font(.largeTitle.weight(.semibold))
                Text("A native Git client for macOS").foregroundStyle(.secondary)
                Button("Open Repository…") {
                    if let url = RepositoryPicker.choose() { open(url) }
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !recents.isEmpty {
                Divider()
                List(recents, id: \.self) { url in
                    Button { open(url) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).font(.headline)
                            Text((url.path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                }
                .frame(width: 300)
            }
        }
    }
}

struct RepoWindow: View {
    @State private var model: RepoModel
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow

    private var resetTitle: String {
        guard let r = model.pendingReset else { return "" }
        return "Reset “\(model.currentBranch ?? "HEAD")” to \(r.commit.shortID)?"
    }

    private var resetMessage: String {
        switch model.pendingReset?.mode {
        case .soft?: "Commits after it are undone; their changes stay staged."
        case .mixed?: "Commits after it are undone; their changes stay in the working tree, unstaged."
        case .hard?: "Commits after it AND all uncommitted changes are discarded. Only the reflog can bring them back."
        case nil: ""
        }
    }

    private var discardTitle: String {
        guard let e = model.pendingDiscardFiles else { return "" }
        return e.count == 1 ? "Discard changes to “\(e[0].change.path)”?" : "Discard changes to \(e.count) files?"
    }

    init(url: URL) {
        _model = State(initialValue: RepoModel(url: url))
    }

    // Split in three so Swift 6.2 (CI) can type-check the modifier chain in time.
    private var chrome: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if let op = model.operation {
                    OperationBanner(model: model, operation: op)
                }
                if model.showsWorkingCopy {
                    WorkingCopyView(model: model)
                } else if let stash = model.selectedStash {
                    StashView(model: model, stash: stash)
                } else {
                    HistoryView(model: model)
                }
            }
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.currentBranch ?? (model.repo == nil ? "" : "detached HEAD"))
        .overlay(alignment: .top) {
            if model.showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                        .onTapGesture { model.showPalette = false }
                    QuickSwitcher(model: model).padding(.top, 70)
                }
            }
        }
        .inspector(isPresented: $model.showActivity) {
            ActivityView(model: model)
                .inspectorColumnWidth(min: 260, ideal: 340, max: 600)
        }
        .toolbar {
            RemoteToolbar(model: model)
            ToolbarItem {
                if model.isLoadingLog {
                    ProgressView().controlSize(.small)
                }
            }
            ToolbarItem {
                Button { model.showStashSheet = true } label: {
                    Label("Stash", systemImage: "archivebox")
                }
                .help("Stash Changes (⌥⌘S)")
                .disabled(model.changes.isEmpty)
            }
            ToolbarItem {
                Button { model.beginNewBranch() } label: {
                    Label("New Branch", systemImage: "arrow.triangle.branch")
                }
                .help("New Branch (⇧⌘N)")
            }
            ToolbarItem {
                Button { model.showActivity.toggle() } label: {
                    Label("Activity", systemImage: "list.bullet.rectangle")
                }
                .help("Show git commands run by Grove (⌥⌘L)")
            }
            ToolbarItem {
                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh (⌘R)")
            }
        }
    }

    private var withSheets: some View {
        chrome
        .sheet(item: $model.branchSheet) { BranchNameSheet(model: model, sheet: $0) }
        .sheet(item: $model.credentialPrompt) { CredentialSheet(prompt: $0) }
        .sheet(isPresented: $model.showStashSheet) { StashSheet(model: model) }
        .sheet(item: $model.tagSheet) { TagSheet(model: model, commit: $0) }
        .sheet(item: $model.blameTarget) { BlameView(model: model, target: $0) }
        .sheet(item: $model.rebaseBase) { InteractiveRebaseSheet(model: model, base: $0) }
        .sheet(item: $model.worktreeSheet) { WorktreeSheet(model: model, ref: $0) }
        .onChange(of: model.openRequest) {
            if let url = model.openRequest {
                openWindow(value: url)
                model.openRequest = nil
            }
        }
    }

    var body: some View {
        withSheets
        .confirmationDialog("Remove worktree “\(model.pendingRemoveWorktree.map { ($0.path as NSString).lastPathComponent } ?? "")”?",
                            isPresented: Binding(get: { model.pendingRemoveWorktree != nil }, set: { if !$0 { model.pendingRemoveWorktree = nil } })) {
            if let w = model.pendingRemoveWorktree {
                Button("Remove") { Task { await model.removeWorktree(w, force: false) } }
                Button("Remove Even With Changes", role: .destructive) { Task { await model.removeWorktree(w, force: true) } }
            }
        } message: {
            Text("The folder is deleted; its branch stays.")
        }
        .confirmationDialog(resetTitle,
                            isPresented: Binding(get: { model.pendingReset != nil }, set: { if !$0 { model.pendingReset = nil } })) {
            if let r = model.pendingReset {
                Button("Reset (\(r.mode.rawValue))", role: r.mode == .hard ? .destructive : nil) {
                    Task { await model.reset(r.mode, to: r.commit) }
                }
            }
        } message: {
            Text(resetMessage)
        }
        .confirmationDialog("Delete tag “\(model.pendingDeleteTag?.name ?? "")”?",
                            isPresented: Binding(get: { model.pendingDeleteTag != nil }, set: { if !$0 { model.pendingDeleteTag = nil } })) {
            Button("Delete", role: .destructive) {
                if let t = model.pendingDeleteTag { Task { await model.deleteTag(t) } }
            }
        } message: {
            Text("Only the local tag is deleted.")
        }
        .confirmationDialog("Drop stash “\(model.pendingDropStash.map(StashView.title) ?? "")”?",
                            isPresented: Binding(get: { model.pendingDropStash != nil }, set: { if !$0 { model.pendingDropStash = nil } })) {
            Button("Drop", role: .destructive) {
                if let s = model.pendingDropStash { Task { await model.dropStash(s) } }
            }
        } message: {
            Text("Dropped stashes can only be recovered by their commit id.")
        }
        .confirmationDialog(discardTitle,
                            isPresented: Binding(get: { model.pendingDiscardFiles != nil }, set: { if !$0 { model.pendingDiscardFiles = nil } })) {
            Button("Discard", role: .destructive) {
                if let e = model.pendingDiscardFiles { Task { await model.discard(e) } }
            }
        } message: {
            Text("Unstaged changes are lost and untracked files are deleted. This can't be undone.")
        }
        .confirmationDialog("Delete branch “\(model.pendingDelete?.name ?? "")”?",
                            isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let ref = model.pendingDelete { Task { await model.deleteBranch(ref, force: false) } }
            }
        }
        .confirmationDialog("“\(model.forceDelete?.name ?? "")” is not fully merged",
                            isPresented: Binding(get: { model.forceDelete != nil }, set: { if !$0 { model.forceDelete = nil } })) {
            Button("Delete Anyway", role: .destructive) {
                if let ref = model.forceDelete { Task { await model.deleteBranch(ref, force: true) } }
            }
        } message: {
            Text("Its commits are not reachable from its upstream or HEAD and will only be recoverable through the reflog.")
        }
        .task { await model.load() }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { model.undoManager = undoManager }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshRefsAndStatus() }
        }
        .focusedSceneValue(\.repoModel, model)
        .alert("Git Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct HistoryView: View {
    @Bindable var model: RepoModel

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HistoryFilterBar(model: model)
                CommitTable(model: model, rowCount: model.displayCount, generation: model.logGeneration,
                            selectedID: model.selectedCommitID, scrollToken: model.scrollToken)
            }
            .frame(minHeight: 160, idealHeight: 380)
            HSplitView {
                CommitDetailPane(model: model)
                    .frame(minWidth: 240, idealWidth: 340, maxWidth: 600)
                DiffPane(text: model.commitDiff, path: model.selectedFileID, blobs: model.commitBlobs)
                    .frame(minWidth: 320)
            }
            .frame(minHeight: 160)
        }
    }
}

struct CommitDetailPane: View {
    @Bindable var model: RepoModel

    var body: some View {
        if let d = model.detail {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(d.message.trimmingCharacters(in: .whitespacesAndNewlines))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                            meta("Author", "\(d.commit.authorName) <\(d.commit.authorEmail)>")
                            meta("Date", d.commit.date.formatted(date: .abbreviated, time: .shortened))
                            meta("Commit", d.commit.id)
                            if !d.commit.parents.isEmpty {
                                meta(d.commit.isMerge ? "Parents" : "Parent",
                                     d.commit.parents.map { String($0.prefix(8)) }.joined(separator: "  "))
                            }
                        }
                        .font(.callout)
                    }
                    .padding(12)
                }
                .frame(maxHeight: 220)
                Divider()
                List(d.files, selection: $model.selectedFileID) { file in
                    FileRow(letter: file.letter, path: file.path, origPath: file.origPath)
                        .contextMenu {
                            Button("Show History of “\((file.path as NSString).lastPathComponent)”") { model.showHistory(of: file.path) }
                            if file.letter != "D" {
                                Button("Blame at This Commit") { model.blameTarget = BlameTarget(path: file.path, revision: d.commit.id) }
                            }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(file.path, forType: .string)
                            }
                        }
                }
                .listStyle(.inset)
            }
        } else {
            ContentUnavailableView("No Commit Selected", systemImage: "point.3.connected.trianglepath.dotted")
        }
    }

    private func meta(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }
}

struct FileRow: View {
    let letter: Character
    let path: String
    var origPath: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(String(letter))
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(Self.color(letter)))
            Text((path as NSString).lastPathComponent).lineLimit(1)
            let dir = (path as NSString).deletingLastPathComponent
            if let origPath {
                Text("← \(origPath)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else if !dir.isEmpty {
                Text(dir).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
        }
        .help(path)
    }

    static func color(_ letter: Character) -> Color {
        switch letter {
        case "A", "?": .green
        case "D": .red
        case "R", "C": .purple
        case "U": .orange
        default: .blue
        }
    }
}

struct HistoryFilterBar: View {
    @Bindable var model: RepoModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter by message, author, SHA or ref", text: $model.historyFilter)
                .textFieldStyle(.plain)
                .focused($focused)
                .autocorrectionDisabled()
                .onExitCommand { model.historyFilter = "" }
            if let path = model.pathFilter {
                HStack(spacing: 3) {
                    Image(systemName: "doc")
                    Text(path).lineLimit(1).truncationMode(.middle)
                    Button { model.pathFilter = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Show all history")
                }
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .frame(maxWidth: 260)
            }
            if model.isFiltering || model.pathFilter != nil {
                Text("\(model.displayCount) commit\(model.displayCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if !model.historyFilter.isEmpty {
                Button { model.historyFilter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: model.focusFilterToken) { focused = true }
    }
}

struct OperationBanner: View {
    let model: RepoModel
    let operation: RepoOperation

    var body: some View {
        let conflicts = model.conflictEntries.count
        HStack(spacing: 10) {
            Image(systemName: conflicts > 0 ? "exclamationmark.triangle.fill" : "arrow.triangle.merge")
                .foregroundStyle(conflicts > 0 ? .orange : .accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold)
                Text(conflicts > 0 ? "\(conflicts) conflicted file\(conflicts == 1 ? "" : "s") — resolve, then Continue"
                                   : "No conflicts left — Continue to finish")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Abort", role: .destructive) { Task { await model.abortOperation() } }
            if operation.canSkip {
                Button("Skip") { Task { await model.skipOperation() } }
            }
            Button("Continue") { Task { await model.continueOperation() } }
                .buttonStyle(.borderedProminent)
                .disabled(conflicts > 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var title: String {
        let branch = model.currentBranch ?? "HEAD"
        switch operation {
        case .merge(let from): return "Merging \(from.map { "“\($0)”" } ?? "") into “\(branch)”"
        case .rebase(let b, let onto, let step, let total):
            let progress = (step != nil && total != nil) ? " — commit \(step!) of \(total!)" : ""
            return "Rebasing “\(b ?? branch)” onto \(onto ?? "")\(progress)"
        case .cherryPick: return "Cherry-pick paused"
        case .revert: return "Revert paused"
        }
    }
}
