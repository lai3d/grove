import GroveCore
import SwiftUI

struct WorkingCopyView: View {
    @Bindable var model: RepoModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selectedChangeID) {
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

    private var commitBox: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $model.commitMessage)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 90)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .overlay(alignment: .topLeading) {
                    if model.commitMessage.isEmpty {
                        Text("Commit message").foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
            Button {
                Task { await model.commit() }
            } label: {
                Text(model.currentBranch.map { "Commit to \($0)" } ?? "Commit")
                    .frame(minWidth: 120)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!model.canCommit)
        }
        .padding(10)
    }
}
