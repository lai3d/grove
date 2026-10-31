import GroveCore
import SwiftUI

struct WorkingCopyView: View {
    @Bindable var model: RepoModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selectedChangeID) {
                    if !model.conflictEntries.isEmpty {
                        conflictSection
                    }
                    section("Staged", entries: model.stagedEntries, action: "Unstage", icon: "minus.circle") {
                        await model.unstage($0)
                    }
                    section("Changes", entries: model.unstagedEntries, action: "Stage", icon: "plus.circle",
                            discard: { model.pendingDiscardFiles = $0 }) {
                        await model.stage($0)
                    }
                }
                .overlay {
                    if model.changes.isEmpty {
                        ContentUnavailableView("Working Tree Clean", systemImage: "checkmark.seal")
                    }
                }
                Divider()
                commitBox
            }
            .frame(minWidth: 280, idealWidth: 360, maxWidth: 640)

            WorkingDiffPane(model: model)
                .frame(minWidth: 320)
        }
    }

    private func section(_ title: String, entries: [ChangeEntry], action: String, icon: String,
                         discard: (([ChangeEntry]) -> Void)? = nil,
                         perform: @escaping ([ChangeEntry]) async -> Void) -> some View {
        Section {
            ForEach(entries) { e in
                HStack {
                    FileRow(letter: Character(e.letter), path: e.change.path, origPath: e.change.origPath)
                    Spacer()
                    Button { Task { await perform([e]) } } label: { Image(systemName: icon) }
                        .buttonStyle(.borderless)
                        .help(action)
                }
                .contextMenu {
                    Button(action) { Task { await perform([e]) } }
                    if e.change.kind != .untracked {
                        Button("Show History") { model.showHistory(of: e.change.path) }
                        if e.change.worktree != "D" {
                            Button("Blame") { model.blameTarget = BlameTarget(path: e.change.path, revision: nil) }
                        }
                    }
                    if let discard {
                        Divider()
                        Button("Discard Changes…") { discard([e]) }
                    }
                }
            }
        } header: {
            HStack {
                Text("\(title) (\(entries.count))")
                Spacer()
                if !entries.isEmpty {
                    if let discard {
                        Button("Discard All…") { discard(entries) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    Button("\(action) All") { Task { await perform(entries) } }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
    }

    /// During a rebase "ours" is the branch being rebased onto and "theirs" is your commit.
    private var sideNames: (ours: String, theirs: String) {
        if case .rebase? = model.operation { return ("Upstream", "Your Commit") }
        return ("Ours", "Theirs")
    }

    private var conflictSection: some View {
        Section {
            ForEach(model.conflictEntries) { e in
                HStack {
                    FileRow(letter: "U", path: e.change.path)
                    Spacer()
                    Menu {
                        Button("Take \(sideNames.ours)") { Task { await model.resolve(e, taking: .ours) } }
                        Button("Take \(sideNames.theirs)") { Task { await model.resolve(e, taking: .theirs) } }
                        Divider()
                        Button("Mark as Resolved") { Task { await model.markResolved(e) } }
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Resolve")
                }
                .contextMenu {
                    Button("Take \(sideNames.ours)") { Task { await model.resolve(e, taking: .ours) } }
                    Button("Take \(sideNames.theirs)") { Task { await model.resolve(e, taking: .theirs) } }
                    Divider()
                    Button("Mark as Resolved (stage as is)") { Task { await model.markResolved(e) } }
                }
            }
        } header: {
            Text("Conflicts (\(model.conflictEntries.count))").foregroundStyle(.orange)
        }
    }

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.commitMessage)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 96)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .overlay(alignment: .topLeading) {
                    if model.commitMessage.isEmpty {
                        Text("Summary\n\nDescription").foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) { subjectCounter.padding(6) }
            if model.amend && model.headIsPushed {
                Label("HEAD is already pushed — amending rewrites published history.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Toggle("Amend", isOn: $model.amend)
                    .help("Replace the last commit (loads its message)")
                Toggle("Sign-off", isOn: $model.signOff)
                    .help("Add a Signed-off-by trailer")
                Spacer()
                Button {
                    Task { await model.commit() }
                } label: {
                    Text(commitTitle).frame(minWidth: 110)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCommit)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .padding(10)
    }

    private var commitTitle: String {
        if model.amend { return "Amend Commit" }
        return model.currentBranch.map { "Commit to \($0)" } ?? "Commit"
    }

    /// First-line length: ≤50 fine, ≤72 orange, beyond red.
    @ViewBuilder private var subjectCounter: some View {
        let subject = model.commitMessage.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        if !subject.isEmpty {
            Text("\(subject.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(subject.count > 72 ? .red : subject.count > 50 ? .orange : .secondary)
                .help("Summary line length (keep it under 50, wrap at 72)")
        }
    }
}
