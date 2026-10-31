import GroveCore
import SwiftUI

struct BlameTarget: Identifiable, Hashable {
    let path: String
    /// nil = working tree.
    let revision: String?
    var id: String { path + "@" + (revision ?? "worktree") }
}

struct BlameView: View {
    let model: RepoModel
    let target: BlameTarget
    @State private var lines: [BlameLine] = []
    @State private var loading = true
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "person.text.rectangle")
                Text(target.path).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(target.revision.map { "at \(String($0.prefix(8)))" } ?? "working tree")
                    .foregroundStyle(.secondary)
                Spacer()
                if !lines.isEmpty {
                    Text("\(lines.count) lines · \(Set(lines.map(\.commitID)).count) commits")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            .background(.bar)
            Divider()
            if loading {
                ProgressView("Running git blame…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Blame Failed", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let range = dateRange
                        ForEach(lines.indices, id: \.self) { i in
                            BlameRow(line: lines[i],
                                     startsBlock: i == 0 || lines[i - 1].commitID != lines[i].commitID,
                                     age: age(lines[i], range)) { jump(to: lines[i]) }
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .frame(minWidth: 960, idealWidth: 1100, minHeight: 600, idealHeight: 760)
        .task {
            guard let repo = model.repo else { return }
            do {
                lines = try await repo.blame(target.path, at: target.revision)
            } catch {
                self.error = "\(error)"
            }
            loading = false
        }
    }

    private var dateRange: ClosedRange<Date> {
        let dates = lines.filter { !$0.isUncommitted }.map(\.date)
        guard let lo = dates.min(), let hi = dates.max(), lo < hi else { return Date.distantPast...Date() }
        return lo...hi
    }

    /// 0 = oldest line, 1 = newest (uncommitted counts as newest).
    private func age(_ line: BlameLine, _ range: ClosedRange<Date>) -> Double {
        if line.isUncommitted { return 1 }
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        return span > 0 ? line.date.timeIntervalSince(range.lowerBound) / span : 1
    }

    private func jump(to line: BlameLine) {
        guard !line.isUncommitted else { return }
        dismiss()
        model.historyFilter = ""
        model.sidebarSelection = .history
        model.jump(to: line.commitID)
    }
}

struct BlameRow: View {
    let line: BlameLine
    let startsBlock: Bool
    let age: Double
    let open: () -> Void
    @AppStorage("diffFontSize") private var diffFontSize = 12.0

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter
                .padding(.vertical, 1)
                .frame(width: 290, alignment: .leading)
                .background(Color.accentColor.opacity(0.04 + 0.22 * age))
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
                .help(line.isUncommitted ? "Not committed yet" : "\(line.summary)\n\(line.author) · \(line.date.formatted())\nClick to show in history")
            Text("\(line.lineNumber)")
                .font(.system(size: diffFontSize - 1, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.vertical, 1)
            Text(line.content.isEmpty ? " " : line.content)
                .font(.system(size: diffFontSize, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
        }
        .overlay(alignment: .top) { if startsBlock { Divider().opacity(0.6) } }
    }

    @ViewBuilder private var gutter: some View {
        if startsBlock {
            HStack(spacing: 6) {
                if line.isUncommitted {
                    Text("Not committed yet").italic().foregroundStyle(.secondary)
                } else {
                    Text(String(line.commitID.prefix(7))).font(.system(size: diffFontSize - 1, design: .monospaced)).foregroundStyle(.secondary)
                    Text(line.author).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(line.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
        } else {
            Color.clear
        }
    }
}
