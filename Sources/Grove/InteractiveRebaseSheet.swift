import GroveCore
import SwiftUI

/// Edit the commits after `base`: reorder by drag, pick / reword / squash / fixup / drop.
struct InteractiveRebaseSheet: View {
    let model: RepoModel
    let base: Commit
    @State private var steps: [RebaseStep] = []
    @State private var loadError: String?
    @State private var loading = true
    @State private var running = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Interactive Rebase").font(.headline)
                Text("Commits after \(base.shortID) “\(base.subject)” on \(model.currentBranch ?? "HEAD") — oldest first. Drag to reorder; squash and fixup fold a commit into the one above it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("Can't Rebase Here", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                List {
                    ForEach($steps) { $step in
                        StepRow(step: $step, isGroupHead: isGroupHead(step), defaultMessage: defaultMessage(for: step))
                    }
                    .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            HStack {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout)
                } else {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rebase") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(loading || loadError != nil || problem != nil || running || !hasChanges)
            }
            .padding(12)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 480, idealHeight: 620)
        .task {
            guard let repo = model.repo else { return }
            do {
                steps = try await repo.rebaseCandidates(after: base.id)
                originalOrder = Dictionary(uniqueKeysWithValues: steps.enumerated().map { ($1.id, $0) })
                if steps.isEmpty { loadError = "There are no commits after this one on the current branch." }
            } catch {
                loadError = (error as? GitError)?.stderr ?? "\(error)"
            }
            loading = false
        }
    }

    private var kept: [RebaseStep] { steps.filter { $0.action != .drop } }

    private var problem: String? {
        guard let first = kept.first else { return steps.isEmpty ? nil : "All commits are dropped" }
        if first.action == .squash || first.action == .fixup { return "The first commit can't be squashed or fixed up" }
        return nil
    }

    private var hasChanges: Bool {
        steps.contains { $0.action != .pick } || steps.map(\.id) != steps.map(\.id).sorted(by: { a, b in
            (originalOrder[a] ?? 0) < (originalOrder[b] ?? 0)
        })
    }

    @State private var originalOrder: [String: Int] = [:]

    private var summary: String {
        let counts = Dictionary(grouping: steps, by: \.action).mapValues(\.count)
        let parts = RebaseStep.Action.allCases.compactMap { a in counts[a].map { "\($0) \(a.rawValue)" } }
        return parts.joined(separator: " · ")
    }

    /// A kept commit that the following squash / fixup commits fold into.
    private func isGroupHead(_ step: RebaseStep) -> Bool {
        guard step.action == .pick || step.action == .reword, let i = kept.firstIndex(where: { $0.id == step.id }) else { return false }
        return i + 1 < kept.count && kept[i + 1].action == .squash
    }

    private func defaultMessage(for step: RebaseStep) -> String {
        guard let i = kept.firstIndex(where: { $0.id == step.id }) else { return step.originalMessage }
        var group = [kept[i]]
        var j = i + 1
        while j < kept.count, kept[j].action == .squash || kept[j].action == .fixup { group.append(kept[j]); j += 1 }
        return group.contains { $0.action == .squash } ? Repository.squashMessage(group) : step.originalMessage
    }

    private func start() {
        running = true
        let plan = steps
        Task {
            dismiss()
            await model.interactiveRebase(onto: base, steps: plan)
        }
    }
}

private struct StepRow: View {
    @Binding var step: RebaseStep
    let isGroupHead: Bool
    let defaultMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                Picker("", selection: $step.action) {
                    ForEach(RebaseStep.Action.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden()
                .frame(width: 100)
                if step.action == .squash || step.action == .fixup {
                    Image(systemName: "arrow.turn.left.up").foregroundStyle(.secondary).help("Folded into the commit above")
                }
                Text(step.commit.shortID).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Text(step.commit.subject)
                    .strikethrough(step.action == .drop)
                    .foregroundStyle(step.action == .drop ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                Text(step.commit.authorName).font(.caption).foregroundStyle(.secondary)
            }
            if step.action == .reword || isGroupHead {
                TextEditor(text: Binding(get: { step.message ?? defaultMessage }, set: { step.message = $0 }))
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                    .padding(.leading, 34)
            }
        }
        .padding(.vertical, 3)
        .opacity(step.action == .drop ? 0.6 : 1)
    }
}
