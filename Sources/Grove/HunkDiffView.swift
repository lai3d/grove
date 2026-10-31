import AppKit
import GroveCore
import SwiftUI

/// Working-copy diff with per-hunk and per-line stage / unstage / discard.
struct WorkingDiffPane: View {
    @Bindable var model: RepoModel

    static let maxLines = 6000

    var body: some View {
        if let entry = model.selectedEntry, entry.change.kind != .untracked, entry.change.kind != .unmerged,
           let diff = model.workingFileDiff, !diff.isBinary, !diff.hunks.isEmpty,
           diff.hunks.reduce(0, { $0 + $1.lines.count }) <= Self.maxLines {
            HunkDiffView(model: model, diff: diff, staged: entry.staged)
        } else {
            DiffPane(text: model.workingDiff, path: model.selectedEntry?.change.path, blobs: model.workingBlobs)
        }
    }
}

struct HunkDiffView: View {
    @Bindable var model: RepoModel
    let diff: FileDiff
    let staged: Bool
    @State private var anchor: (hunk: Int, line: Int)?
    private let styler: DiffStyler
    private let words: [[Int: [NSRange]]]

    init(model: RepoModel, diff: FileDiff, staged: Bool) {
        self.model = model
        self.diff = diff
        self.staged = staged
        styler = DiffStyler(path: diff.newPath ?? diff.oldPath ?? "")
        words = diff.hunks.map(DiffStyler.wordRanges)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(Array(diff.hunks.enumerated()), id: \.offset) { h, hunk in
                    Section {
                        // IDs must be unique across sections of one LazyVStack.
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { i, line in
                            DiffLineRow(line: line, selected: model.selectedLines[h]?.contains(i) == true,
                                        text: styler.text(line, changed: words[h][i] ?? []))
                                .contentShape(Rectangle())
                                .onTapGesture { toggle(hunk: h, line: i) }
                                .id("\(h)-\(i)")
                        }
                        Spacer().frame(height: 10)
                    } header: {
                        header(h, hunk)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .confirmationDialog("Discard these changes?",
                            isPresented: Binding(get: { model.pendingDiscard != nil }, set: { if !$0 { model.pendingDiscard = nil } })) {
            Button("Discard", role: .destructive) {
                if let p = model.pendingDiscard { Task { await model.applyHunk(.discard, hunk: p.hunk, lines: p.lines) } }
            }
        } message: {
            Text("The working tree copy is changed; this can't be undone.")
        }
    }

    private func header(_ h: Int, _ hunk: DiffHunk) -> some View {
        let selection = model.selectedLines[h].flatMap { $0.isEmpty ? nil : $0 }
        let noun = selection == nil ? "Hunk" : (selection!.count == 1 ? "Line" : "Lines")
        return HStack(spacing: 8) {
            Text(hunk.header)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if staged {
                Button("Unstage \(noun)") { Task { await model.applyHunk(.unstage, hunk: h, lines: selection) } }
            } else {
                Button("Discard \(noun)…") { model.pendingDiscard = (h, selection) }
                Button("Stage \(noun)") { Task { await model.applyHunk(.stage, hunk: h, lines: selection) } }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Click toggles a changed line; shift-click selects the range from the last click.
    private func toggle(hunk h: Int, line i: Int) {
        let lines = diff.hunks[h].lines
        guard lines[i].isChange else { return }
        var set = model.selectedLines[h] ?? []
        if NSEvent.modifierFlags.contains(.shift), let a = anchor, a.hunk == h {
            for j in min(a.line, i)...max(a.line, i) where lines[j].isChange { set.insert(j) }
        } else if set.contains(i) {
            set.remove(i)
        } else {
            set.insert(i)
        }
        // Selection is per hunk: clicking in another hunk starts over there.
        model.selectedLines = [h: set]
        anchor = (h, i)
    }
}

struct DiffLineRow: View {
    let line: DiffLine
    let selected: Bool
    var text: AttributedString?
    @AppStorage("diffFontSize") private var diffFontSize = 12.0

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(AttributedString(prefix) + (text ?? AttributedString(line.text)) + AttributedString(line.noNewline ? "  ⏎̸" : ""))
                .font(.system(size: diffFontSize, design: .monospaced))
                .foregroundStyle(line.kind == .context ? Color.primary.opacity(0.85) : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
        .background(background)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color.accentColor).frame(width: 3) }
        }
    }

    private var prefix: String {
        switch line.kind {
        case .context: " "
        case .added: "+"
        case .removed: "-"
        }
    }

    private var background: Color {
        let base: Color = switch line.kind {
        case .context: .clear
        case .added: .green.opacity(0.16)
        case .removed: .red.opacity(0.16)
        }
        return selected ? Color.accentColor.opacity(0.28) : base
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: diffFontSize - 1, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 4)
    }
}
