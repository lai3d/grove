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
    @State private var session: MergeSession?
    @State private var loadError: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    /// During a rebase "ours" is the branch being rebased onto, "theirs" your commit.
    private var names: (ours: String, theirs: String) { MergeSession.sideNames(for: model.operation) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let session {
                HSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(session.file.conflicts.enumerated()), id: \.offset) { k, c in
                                card(k, c)
                            }
                        }
                        .padding(14)
                    }
                    .frame(minWidth: 520)
                    preview(session).frame(minWidth: 280, idealWidth: 360)
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
            if let session {
                Text("\(session.resolvedCount) of \(session.conflictCount) conflicts resolved")
                    .font(.callout).foregroundStyle(session.isComplete ? .green : .secondary)
                Menu("All") {
                    Button("Take \(names.ours) Everywhere") { self.session?.chooseAll(.ours) }
                    Button("Take \(names.theirs) Everywhere") { self.session?.chooseAll(.theirs) }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save & Mark Resolved") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(session?.isComplete != true || saving)
        }
        .padding(10)
        .background(.bar)
    }

    private func card(_ k: Int, _ c: ConflictFile.Conflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Conflict \(k + 1)").font(.subheadline.weight(.semibold)).fixedSize()
                Spacer()
                if session?.choice(k) == nil {
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
                side("\(names.ours) — \(c.oursLabel)", c.ours, .blue, active: session?.includesOurs(k) == true)
                side("\(names.theirs) — \(c.theirsLabel)", c.theirs, .purple, active: session?.includesTheirs(k) == true)
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
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(session?.choice(k) == nil ? Color.orange.opacity(0.6) : Color.green.opacity(0.5)))
    }

    @ViewBuilder
    private func choiceButton(_ k: Int, _ choice: ConflictFile.Choice, _ title: String) -> some View {
        if session?.choice(k) == choice {
            Button(title) { session?.toggle(k, choice) }.buttonStyle(.borderedProminent)
        } else {
            Button(title) { session?.toggle(k, choice) }.buttonStyle(.bordered)
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

    private func preview(_ session: MergeSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Result").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(8)
            Divider()
            ScrollView {
                Text(session.result)
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
        switch MergeSession.load(path: target.path, data: repo.workingFile(target.path)) {
        case .success(let s): session = s
        case .failure(.notText): loadError = "The file isn't UTF-8 text. Use Take \(names.ours) / Take \(names.theirs) instead."
        case .failure(.noMarkers): loadError = "No conflict markers found — the file may already be edited. Stage it with Mark as Resolved."
        }
    }

    private func save() {
        guard let session else { return }
        saving = true
        Task {
            await model.saveResolution(session.path, text: session.result)
            dismiss()
        }
    }
}
