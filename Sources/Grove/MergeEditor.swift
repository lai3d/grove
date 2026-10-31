import GroveCore
import SwiftUI

struct MergeEditorTarget: Identifiable, Hashable {
    let path: String
    var id: String { path }
}

/// Resolve a conflicted text file conflict by conflict: ours / theirs / both, with a live preview.
struct MergeEditorSheet: View {
    let model: RepoModel
    let target: MergeEditorTarget
    @State private var file: ConflictFile?
    @State private var loadError: String?
    @State private var choices: [Int: ConflictFile.Choice] = [:]
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    /// During a rebase "ours" is the branch being rebased onto, "theirs" your commit.
    private var names: (ours: String, theirs: String) {
        if case .rebase? = model.operation { return ("Upstream", "Your Commit") }
        return ("Ours", "Theirs")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let file {
                HSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(file.conflicts.enumerated()), id: \.offset) { k, c in
                                card(k, c)
                            }
                        }
                        .padding(14)
                    }
                    .frame(minWidth: 520)
                    preview(file).frame(minWidth: 280, idealWidth: 360)
                }
            } else {
                ContentUnavailableView("Can't Open in the Merge Editor", systemImage: "doc.questionmark",
                                       description: Text(loadError ?? "Loading…"))
            }
        }
        .frame(minWidth: 960, idealWidth: 1120, minHeight: 600, idealHeight: 760)
        .task { load() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "arrow.triangle.merge")
            Text(target.path).font(.headline).lineLimit(1).truncationMode(.middle)
            if let file {
                Text("\(choices.count) of \(file.conflicts.count) conflicts resolved")
                    .font(.callout).foregroundStyle(choices.count == file.conflicts.count ? .green : .secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save & Mark Resolved") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(file == nil || choices.count != file!.conflicts.count || saving)
        }
        .padding(10)
        .background(.bar)
    }

    private func card(_ k: Int, _ c: ConflictFile.Conflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Conflict \(k + 1)").font(.subheadline.weight(.semibold)).fixedSize()
                Spacer()
                if choices[k] == nil {
                    Text("Choose a side").font(.caption).foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            HStack(spacing: 6) {
                choiceButton(k, .ours, names.ours)
                choiceButton(k, .theirs, names.theirs)
                choiceButton(k, .oursThenTheirs, "Both")
                choiceButton(k, .theirsThenOurs, "Both, \(names.theirs.lowercased()) first")
                if c.base != nil { choiceButton(k, .base, "Base") }
            }
            .controlSize(.small)
            HStack(alignment: .top, spacing: 8) {
                side("\(names.ours) — \(c.oursLabel)", c.ours, .blue, active: [.ours, .oursThenTheirs, .theirsThenOurs].contains(choices[k]))
                side("\(names.theirs) — \(c.theirsLabel)", c.theirs, .purple, active: [.theirs, .oursThenTheirs, .theirsThenOurs].contains(choices[k]))
            }
            if let base = c.base {
                DisclosureGroup("Common ancestor") {
                    code(base).padding(6).background(RoundedRectangle(cornerRadius: 6).fill(.gray.opacity(0.08)))
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(choices[k] == nil ? Color.orange.opacity(0.6) : Color.green.opacity(0.5)))
    }

    @ViewBuilder
    private func choiceButton(_ k: Int, _ choice: ConflictFile.Choice, _ title: String) -> some View {
        if choices[k] == choice {
            Button(title) { choices[k] = nil }.buttonStyle(.borderedProminent)
        } else {
            Button(title) { choices[k] = choice }.buttonStyle(.bordered)
        }
    }

    private func side(_ title: String, _ lines: [String], _ tint: Color, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint).lineLimit(1)
            code(lines)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(active ? 0.16 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(active ? 0.7 : 0.15)))
        }
        .frame(maxWidth: .infinity)
    }

    private func code(_ lines: [String]) -> some View {
        Text(lines.isEmpty ? "(nothing)" : lines.joined(separator: "\n"))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(lines.isEmpty ? .secondary : .primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func preview(_ file: ConflictFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Result").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(8)
            Divider()
            ScrollView {
                Text(file.resolved(choices))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func load() {
        guard let repo = model.repo else { return }
        guard let data = repo.workingFile(target.path), let text = String(data: data, encoding: .utf8) else {
            loadError = "The file isn't UTF-8 text. Use Take \(names.ours) / Take \(names.theirs) instead."
            return
        }
        guard let f = ConflictFile(text) else {
            loadError = "No conflict markers found — the file may already be edited. Stage it with Mark as Resolved."
            return
        }
        file = f
    }

    private func save() {
        guard let file else { return }
        saving = true
        let text = file.resolved(choices)
        Task {
            await model.saveResolution(target.path, text: text)
            dismiss()
        }
    }
}
