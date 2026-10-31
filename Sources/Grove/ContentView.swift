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

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
        } detail: {
            if model.showsWorkingCopy {
                WorkingCopyView(model: model)
            } else if let stash = model.selectedStash {
                StashView(model: model, stash: stash)
            } else {
                HistoryView(model: model)
            }
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.currentBranch ?? (model.repo == nil ? "" : "detached HEAD"))
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
        .sheet(item: $model.branchSheet) { BranchNameSheet(model: model, sheet: $0) }
        .sheet(item: $model.credentialPrompt) { CredentialSheet(prompt: $0) }
        .sheet(isPresented: $model.showStashSheet) { StashSheet(model: model) }
        .sheet(item: $model.tagSheet) { TagSheet(model: model, commit: $0) }
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
            CommitTable(model: model, rowCount: model.rows.count, generation: model.logGeneration,
                        selectedID: model.selectedCommitID, scrollToken: model.scrollToken)
                .frame(minHeight: 160, idealHeight: 380)
            HSplitView {
                CommitDetailPane(model: model)
                    .frame(minWidth: 240, idealWidth: 340, maxWidth: 600)
                DiffView(text: model.commitDiff)
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
