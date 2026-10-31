import GroveCore
import SwiftUI

struct ReflogView: View {
    @Bindable var model: RepoModel

    var body: some View {
        VSplitView {
            List(model.reflog, selection: $model.selectedReflogIndex) { entry in
                ReflogRow(entry: entry, current: entry.index == 0)
                    .tag(entry.index)
            }
            .frame(minHeight: 160, idealHeight: 320)
            HSplitView {
                detail.frame(minWidth: 260, idealWidth: 340, maxWidth: 600)
                DiffPane(text: model.reflogDiff, path: model.reflogFileID, blobs: model.reflogBlobs)
                    .frame(minWidth: 320)
            }
            .frame(minHeight: 160)
        }
        .overlay {
            if model.reflog.isEmpty {
                ContentUnavailableView("No Reflog Yet", systemImage: "arrow.uturn.backward.circle",
                                       description: Text("HEAD hasn't moved in this repository yet."))
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let c = model.reflogCommit, let i = model.selectedReflogIndex, model.reflog.indices.contains(i) {
            let entry = model.reflog[i]
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(c.subject).font(.headline).textSelection(.enabled)
                    Text("\(c.shortID) · \(c.authorName) · \(entry.selector)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    let reachable = model.rowIndex[c.id] != nil
                    if !reachable {
                        Label("Not on any branch — create a branch to keep it.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("New Branch Here…") {
                            model.branchSheet = .create(startPoint: c.id, label: "\(c.shortID) “\(c.subject)”")
                        }
                        Menu("More") {
                            Button("Show in History") {
                                model.sidebarSelection = .history
                                model.jump(to: c.id)
                            }
                            .disabled(!reachable)
                            Button("Check Out (Detached)") { Task { await model.checkoutDetached(c.id) } }
                            Divider()
                            Button("Reset “\(model.currentBranch ?? "HEAD")” to Here (keep changes)…") { model.pendingReset = (c, .mixed) }
                            Button("Reset “\(model.currentBranch ?? "HEAD")” to Here (discard changes)…") { model.pendingReset = (c, .hard) }
                        }
                        .fixedSize()
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                .padding(12)
                Divider()
                List(model.reflogFiles, selection: $model.reflogFileID) { f in
                    FileRow(letter: f.letter, path: f.path, origPath: f.origPath)
                }
                .listStyle(.inset)
            }
        } else {
            ContentUnavailableView("Select an Entry", systemImage: "arrow.uturn.backward.circle")
        }
    }
}

private struct ReflogRow: View {
    let entry: ReflogEntry
    let current: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            Text(entry.action).font(.callout.weight(.medium)).foregroundStyle(color)
            Text(Self.shortenSHAs(entry.message)).lineLimit(1).truncationMode(.tail)
            Spacer()
            if current { Text("HEAD").font(.caption2.weight(.bold)).padding(.horizontal, 5).background(Capsule().fill(.blue.opacity(0.2))) }
            Text(String(entry.commitID.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(entry.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
        }
    }

    /// "moving to a98aa0cee790d7b9989be4d6c1c5cd27d5792434" → "moving to a98aa0ce"
    static func shortenSHAs(_ s: String) -> String {
        s.replacingOccurrences(of: #"\b([0-9a-f]{8})[0-9a-f]{32}\b"#, with: "$1", options: .regularExpression)
    }

    private var kind: String { entry.action.split(separator: " ").first.map(String.init) ?? entry.action }

    private var icon: String {
        switch kind {
        case "commit": entry.action.contains("amend") ? "pencil.circle" : "plus.circle"
        case "checkout": "arrow.triangle.branch"
        case "reset": "arrow.uturn.backward"
        case "rebase": "arrow.triangle.pull"
        case "merge": "arrow.triangle.merge"
        case "pull": "arrow.down.circle"
        case "cherry-pick": "leaf"
        case "revert": "arrow.counterclockwise"
        default: "circle"
        }
    }

    private var color: Color {
        switch kind {
        case "reset": .orange
        case "rebase": .purple
        case "merge": .teal
        default: .primary
        }
    }
}
