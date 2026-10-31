import GroveCore
import SwiftUI

struct StashView: View {
    @Bindable var model: RepoModel
    let stash: Stash

    /// "On main: wip one" → "wip one"; "WIP on main: abc123 subject" stays as is.
    static func title(_ stash: Stash) -> String {
        if stash.message.hasPrefix("On "), let colon = stash.message.firstIndex(of: ":") {
            return String(stash.message[stash.message.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return stash.message
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.title(stash)).font(.headline).textSelection(.enabled)
                    Text("\(stash.name) · \(stash.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Apply") { Task { await model.applyStash(stash, pop: false) } }
                        Button("Pop") { Task { await model.applyStash(stash, pop: true) } }
                            .help("Apply and drop")
                        Spacer()
                        Button("Drop…", role: .destructive) { model.pendingDropStash = stash }
                    }
                    .padding(.top, 4)
                }
                .padding(12)
                Divider()
                List(model.stashFiles, selection: $model.selectedStashFileID) { f in
                    FileRow(letter: f.letter, path: f.path, origPath: f.origPath)
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 240, idealWidth: 320, maxWidth: 560)
            DiffView(text: model.stashDiff)
                .frame(minWidth: 320)
        }
    }
}

struct StashSheet: View {
    let model: RepoModel
    @State private var message = ""
    @State private var includeUntracked = true
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stash Changes").font(.headline)
            TextField("Message (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Toggle("Include untracked files", isOn: $includeUntracked)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Stash", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        Task {
            if let e = await model.stashChanges(message: message, includeUntracked: includeUntracked) {
                error = e
            } else {
                dismiss()
            }
        }
    }
}

struct TagSheet: View {
    let model: RepoModel
    let commit: Commit
    @State private var name = ""
    @State private var message = ""
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Tag").font(.headline)
            Text("At \(commit.shortID) “\(commit.subject)”").foregroundStyle(.secondary).lineLimit(2)
            TextField("Tag name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Message (optional — makes an annotated tag)", text: $message, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            if let problem, !name.isEmpty {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || problem != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task(id: name) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            problem = await model.validateTagName(name)
        }
    }

    private func create() {
        Task {
            if let e = await model.createTag(name, at: commit, message: message) { problem = e } else { dismiss() }
        }
    }
}
