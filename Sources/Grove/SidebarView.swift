import GroveCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: RepoModel
    @State private var showBranches = true
    @State private var showRemotes = true
    @State private var showTags = true
    @State private var showStashes = true
    @State private var showWorktrees = true
    @State private var showSubmodules = true

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section("Workspace") {
                Label("Working Copy", systemImage: "square.and.pencil")
                    .badge(model.changes.count)
                    .tag(SidebarItem.workingCopy)
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.history)
                Label("Reflog", systemImage: "arrow.uturn.backward.circle")
                    .tag(SidebarItem.reflog)
                    .help("Everywhere HEAD has been — recover commits lost to resets, rebases or deleted branches")
            }
            let local = filtered(.branch)
            if !local.isEmpty {
                Section("Branches", isExpanded: $showBranches) {
                    grouped(local, key: { folder(of: $0.name) }, prefix: "folder")
                }
            }
            let remote = filtered(.remote)
            if !remote.isEmpty {
                Section("Remotes", isExpanded: $showRemotes) {
                    grouped(remote, key: { $0.name.split(separator: "/").first.map(String.init) }, prefix: "remote",
                            icon: "cloud")
                }
            }
            if !model.stashes.isEmpty {
                Section("Stashes", isExpanded: $showStashes) {
                    ForEach(model.stashes) { stash in
                        HStack {
                            Label(StashView.title(stash), systemImage: "archivebox").lineLimit(1)
                            Spacer()
                            Text(stash.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(SidebarItem.stash(stash.id))
                        .help(stash.message)
                    }
                }
            }
            let otherWorktrees = model.worktrees.filter { $0.path != model.repo?.root.path }
            if !otherWorktrees.isEmpty {
                Section("Worktrees", isExpanded: $showWorktrees) {
                    ForEach(otherWorktrees) { w in
                        HStack {
                            Label((w.path as NSString).lastPathComponent, systemImage: w.isMain ? "house" : "folder.badge.gearshape")
                                .lineLimit(1)
                            Spacer()
                            Text(w.branch ?? "detached").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(SidebarItem.worktree(w.path))
                        .help(w.path)
                    }
                }
            }
            if !model.submodules.isEmpty {
                Section("Submodules", isExpanded: $showSubmodules) {
                    ForEach(model.submodules) { sub in
                        HStack {
                            Label(sub.path, systemImage: "shippingbox").lineLimit(1)
                            Spacer()
                            switch sub.state {
                            case .notInitialized: Text("not initialized").font(.caption).foregroundStyle(.secondary)
                            case .differentCommit: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange).help("Checked-out commit differs from the one recorded")
                            case .conflict: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            case .upToDate: EmptyView()
                            }
                        }
                        .tag(SidebarItem.submodule(sub.path))
                        .help("\(sub.path) @ \(sub.commit.prefix(8))\(sub.describe.map { " (\($0))" } ?? "")")
                    }
                }
            }
            let tags = filtered(.tag)
            if !tags.isEmpty {
                Section("Tags", isExpanded: $showTags) {
                    ForEach(tags) { RefRow(ref: $0, current: false) }
                }
            }
        }
        // A plain filter bar (Xcode-style): `.searchable` in a sidebar hides non-matching sections while searching.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                TextField("Filter branches", text: $model.sidebarFilter)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !model.sidebarFilter.isEmpty {
                    Button { model.sidebarFilter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if let ref = ref(in: items) { RefMenu(model: model, ref: ref) }
            if case .worktree(let path)? = items.first, let w = model.worktrees.first(where: { $0.path == path }) {
                Button("Open in New Window") { model.openRequest = URL(fileURLWithPath: w.path) }
                Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: w.path) }
                if !w.isMain {
                    Divider()
                    Button("Remove Worktree…") { model.pendingRemoveWorktree = w }
                }
            }
            if case .submodule(let path)? = items.first, let sub = model.submodules.first(where: { $0.path == path }) {
                Button("Open in New Window") { model.open(sub) }.disabled(sub.state == .notInitialized)
                Button(sub.state == .notInitialized ? "Initialize" : "Update to Recorded Commit") {
                    Task { await model.updateSubmodule(sub) }
                }
            }
            if case .stash(let id)? = items.first, let stash = model.stashes.first(where: { $0.id == id }) {
                Button("Apply") { Task { await model.applyStash(stash, pop: false) } }
                Button("Pop") { Task { await model.applyStash(stash, pop: true) } }
                Divider()
                Button("Drop…") { model.pendingDropStash = stash }
            }
        } primaryAction: { items in
            switch items.first {
            case .worktree(let path)?: model.openRequest = URL(fileURLWithPath: path)
            case .submodule(let path)?:
                if let sub = model.submodules.first(where: { $0.path == path }) { model.open(sub) }
            default:
                if let ref = ref(in: items) { Task { await model.checkout(ref) } }
            }
        }
        .onAppear {
            // Expand small remotes by default; big ones stay collapsed.
            for (name, refs) in Dictionary(grouping: model.refs.filter { $0.kind == .remote },
                                           by: { $0.name.split(separator: "/").first.map(String.init) ?? "" })
            where refs.count <= 30 {
                model.expandedGroups.insert("remote:\(name)")
            }
        }
    }

    private func ref(in items: Set<SidebarItem>) -> Ref? {
        guard case .ref(let id)? = items.first else { return nil }
        return model.ref(id: id)
    }

    private func filtered(_ kind: Ref.Kind) -> [Ref] {
        let f = model.sidebarFilter.trimmingCharacters(in: .whitespaces)
        return model.refs.filter { $0.kind == kind && (f.isEmpty || $0.name.localizedCaseInsensitiveContains(f)) }
    }

    private func folder(of name: String) -> String? {
        guard let slash = name.firstIndex(of: "/") else { return nil }
        return String(name[..<slash])
    }

    /// Refs with a group key go in a collapsible group (by folder / remote); the rest are listed flat.
    /// While filtering, everything is flat so matches are visible.
    @ViewBuilder
    private func grouped(_ refs: [Ref], key: @escaping (Ref) -> String?, prefix: String, icon: String = "folder") -> some View {
        if !model.sidebarFilter.isEmpty {
            ForEach(refs) { RefRow(ref: $0, current: model.isCurrent($0)) }
        } else {
            let groups = Dictionary(grouping: refs.filter { key($0) != nil }, by: { key($0)! })
            let loose = refs.filter { key($0) == nil || groups[key($0)!]!.count == 1 && prefix == "folder" }
            ForEach(loose) { RefRow(ref: $0, current: model.isCurrent($0)) }
            ForEach(groups.keys.sorted(), id: \.self) { name in
                let members = groups[name]!
                if prefix != "folder" || members.count > 1 {
                    DisclosureGroup(isExpanded: expansion("\(prefix):\(name)")) {
                        ForEach(members) { RefRow(ref: $0, current: model.isCurrent($0), trimPrefix: name + "/") }
                    } label: {
                        Label(name, systemImage: icon).badge(members.count)
                    }
                }
            }
        }
    }

    private func expansion(_ key: String) -> Binding<Bool> {
        Binding(get: { model.expandedGroups.contains(key) },
                set: { if $0 { model.expandedGroups.insert(key) } else { model.expandedGroups.remove(key) } })
    }
}

struct RefRow: View {
    let ref: Ref
    let current: Bool
    var trimPrefix: String?

    var body: some View {
        let shown = trimPrefix.flatMap { ref.name.hasPrefix($0) ? String(ref.name.dropFirst($0.count)) : nil } ?? ref.name
        HStack {
            Label(shown, systemImage: current ? "checkmark.circle.fill" : icon)
                .fontWeight(current ? .semibold : .regular)
                .lineLimit(1)
            Spacer()
            if !ref.track.isEmpty {
                Text(Self.trackSummary(ref.track)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .tag(SidebarItem.ref(ref.id))
        .help(ref.upstream.map { "\(ref.name) — tracking \($0)" } ?? ref.name)
    }

    private var icon: String {
        switch ref.kind {
        case .branch: "arrow.triangle.branch"
        case .remote: "arrow.triangle.branch"
        case .tag: "tag"
        }
    }

    /// "[ahead 2, behind 1]" → "↑2 ↓1"
    static func trackSummary(_ track: String) -> String {
        track.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "ahead ", with: "↑")
            .replacingOccurrences(of: "behind ", with: "↓")
            .replacingOccurrences(of: ",", with: "")
    }
}

struct RefMenu: View {
    let model: RepoModel
    let ref: Ref

    var body: some View {
        let current = model.isCurrent(ref)
        switch ref.kind {
        case .branch:
            Button("Check Out “\(ref.name)”") { Task { await model.checkout(ref) } }.disabled(current)
        case .remote:
            Button("Check Out as Tracking Branch") { Task { await model.checkout(ref) } }
        case .tag:
            Button("Check Out (Detached)") { Task { await model.checkout(ref) } }
        }
        if !current, let cur = model.currentBranch, model.operation == nil {
            Divider()
            Button("Merge “\(ref.name)” into “\(cur)”") { Task { await model.merge(ref.fullName) } }
            Button("Rebase “\(cur)” onto “\(ref.name)”") { Task { await model.rebase(onto: ref.fullName) } }
            Divider()
        }
        if !current {
            Button("Check Out in New Worktree…") { model.worktreeSheet = ref }
        }
        Button("New Branch from “\(ref.name)”…") {
            model.branchSheet = .create(startPoint: ref.fullName, label: ref.name)
        }
        if ref.kind == .branch {
            Divider()
            Button("Rename…") { model.branchSheet = .rename(ref) }
            Button("Delete…") { model.pendingDelete = ref }.disabled(current)
        }
        if ref.kind == .tag {
            Divider()
            Button("Delete Tag…") { model.pendingDeleteTag = ref }
        }
        if let h = model.hosted, let remoteBranch = model.hostedBranch(for: ref) {
            Divider()
            Button("Open on \(h.host.rawValue)") { model.openWeb(h.branch(remoteBranch)) }
            Button("Create \(h.host == .gitlab ? "Merge" : "Pull") Request") { model.openWeb(h.newPullRequest(from: remoteBranch)) }
            Button("Show \(h.host == .gitlab ? "Merge" : "Pull") Requests") { model.openWeb(h.pullRequests(for: remoteBranch)) }
        } else if let h = model.hosted, ref.kind == .tag {
            Divider()
            Button("Open on \(h.host.rawValue)") { model.openWeb(h.branch(ref.name)) }
        }
        Divider()
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ref.name, forType: .string)
        }
    }
}

struct BranchNameSheet: View {
    let model: RepoModel
    let sheet: BranchSheet
    @State private var name: String
    @State private var checkout = true
    @State private var problem: String?
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    init(model: RepoModel, sheet: BranchSheet) {
        self.model = model
        self.sheet = sheet
        if case .rename(let ref) = sheet { _name = State(initialValue: ref.name) } else { _name = State(initialValue: "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch sheet {
            case .create(_, let label):
                Text("New Branch").font(.headline)
                Text("Starting at \(label)").foregroundStyle(.secondary).lineLimit(2)
            case .rename(let ref):
                Text("Rename “\(ref.name)”").font(.headline)
            }
            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if case .create = sheet {
                Toggle("Check out the new branch", isOn: $checkout)
            }
            if let problem, !name.isEmpty {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isCreate ? "Create" : "Rename", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || problem != nil || working)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task(id: name) {
            if case .rename(let ref) = sheet, name == ref.name { problem = "Choose a new name"; return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            problem = await model.validateBranchName(name)
        }
    }

    private var isCreate: Bool { if case .create = sheet { true } else { false } }

    private func submit() {
        guard !name.isEmpty, problem == nil, !working else { return }
        working = true
        Task {
            let error: String? = switch sheet {
            case .create(let start, _): await model.createBranch(name, at: start, checkout: checkout)
            case .rename(let ref): await model.renameBranch(ref, to: name)
            }
            working = false
            if let error { problem = error } else { dismiss() }
        }
    }
}

struct WorktreeSheet: View {
    let model: RepoModel
    let ref: Ref
    @State private var path = ""
    @State private var error: String?
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Worktree").font(.headline)
            Text("Check out “\(ref.name)” in its own folder, so you can work on it alongside the current branch.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Folder", text: $path).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                Button("Choose…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = (path as NSString).lastPathComponent
                    panel.directoryURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create and Open") {
                    working = true
                    Task {
                        if let e = await model.addWorktree(for: ref, at: path) { error = e; working = false } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.isEmpty || working || FileManager.default.fileExists(atPath: path))
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { path = model.suggestedWorktreePath(for: ref.name) }
    }
}
