import AppKit
import GroveCore
import SwiftUI

struct PaletteItem: Identifiable {
    enum Kind { case command, branch, remote, tag, commit }
    let id: String
    let kind: Kind
    let title: String
    var subtitle: String?
    let icon: String
    var shortcut: String?
    var score: Int
    let run: @MainActor () -> Void
    /// ⌘↩ — e.g. check out instead of jump.
    var alternate: (@MainActor () -> Void)?
}

/// ⌘K: jump to a branch / tag / commit, or run a command (prefix ">").
struct QuickSwitcher: View {
    @Bindable var model: RepoModel
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: query.hasPrefix(">") ? "command" : "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Jump to branch, tag or commit — type > for commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .onKeyPress(.downArrow) { move(1, in: items); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
                    .onKeyPress(.return, phases: .down) { press in
                        guard items.indices.contains(selected) else { return .handled }
                        run(items[selected], alternate: press.modifiers.contains(.command))
                        return .handled
                    }
                    .onExitCommand { close() }
            }
            .padding(12)
            if !items.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                row(item, highlighted: i == selected)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { run(item, alternate: NSEvent.modifierFlags.contains(.command)) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(380, items.reduce(12) { $0 + ($1.subtitle == nil ? 32 : 44) }))
                    .onChange(of: selected) { if items.indices.contains(selected) { proxy.scrollTo(items[selected].id) } }
                }
            }
            HStack(spacing: 14) {
                hint("↩", "Go")
                hint("⌘↩", "Check out")
                hint(">", "Commands")
                hint("esc", "Close")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .frame(width: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 24, y: 10)
        .onAppear { focused = true }
        .onChange(of: query) { selected = 0 }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.caption.monospaced()).padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 3).fill(.quaternary))
            Text(label)
        }
    }

    private func row(_ item: PaletteItem, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .frame(width: 18)
                .foregroundStyle(highlighted ? .white : color(item.kind))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if let sub = item.subtitle {
                    Text(sub).font(.caption).lineLimit(1)
                        .foregroundStyle(highlighted ? .white.opacity(0.8) : .secondary)
                }
            }
            Spacer()
            if let s = item.shortcut {
                Text(s).font(.caption.monospaced()).foregroundStyle(highlighted ? .white.opacity(0.85) : .secondary)
            }
        }
        .foregroundStyle(highlighted ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(highlighted ? Color.accentColor : .clear))
    }

    private func color(_ kind: PaletteItem.Kind) -> Color {
        switch kind {
        case .command: .secondary
        case .branch: .green
        case .remote: .gray
        case .tag: .orange
        case .commit: .blue
        }
    }

    private func move(_ d: Int, in items: [PaletteItem]) {
        guard !items.isEmpty else { return }
        selected = (selected + d + items.count) % items.count
    }

    private func close() { model.showPalette = false }

    private func run(_ item: PaletteItem, alternate: Bool) {
        close()
        if alternate, let alt = item.alternate { alt() } else { item.run() }
    }

    // MARK: Results

    private var results: [PaletteItem] {
        let raw = query.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix(">") {
            let q = raw.dropFirst().trimmingCharacters(in: .whitespaces)
            return ranked(commands, q)
        }
        if raw.isEmpty {
            // Local branches first (current one excluded), then commands.
            let branches = refItems.filter { $0.kind == .branch && $0.title != model.currentBranch }
            return Array((branches.prefix(8) + commands.prefix(6)))
        }
        var items = ranked(refItems + commands, raw)
        items += commitItems(raw)
        return Array(items.prefix(60))
    }

    private func ranked(_ items: [PaletteItem], _ q: String) -> [PaletteItem] {
        guard !q.isEmpty else { return items }
        return items.compactMap { item -> PaletteItem? in
            guard let s = Fuzzy.score(q, item.title) else { return nil }
            var copy = item
            copy.score = s + (item.kind == .branch ? 15 : 0)
            return copy
        }
        .sorted { $0.score > $1.score }
    }

    private var refItems: [PaletteItem] {
        model.refs.map { ref in
            let kind: PaletteItem.Kind = switch ref.kind {
            case .branch: .branch
            case .remote: .remote
            case .tag: .tag
            }
            return PaletteItem(
                id: "ref:" + ref.id, kind: kind, title: ref.name,
                subtitle: ref.upstream.map { "tracking \($0)" + (ref.track.isEmpty ? "" : " " + RefRow.trackSummary(ref.track)) },
                icon: ref.kind == .tag ? "tag" : (ref.kind == .remote ? "cloud" : "arrow.triangle.branch"),
                score: 0,
                run: { [model] in model.sidebarSelection = .ref(ref.id) },
                alternate: { [model] in Task { await model.checkout(ref) } })
        }
    }

    /// Substring / SHA-prefix search over loaded commits (fast enough for very large histories).
    private func commitItems(_ q: String) -> [PaletteItem] {
        guard q.count >= 3 else { return [] }
        let isHex = q.count >= 4 && q.allSatisfy(\.isHexDigit)
        let lower = q.lowercased()
        var out: [PaletteItem] = []
        for row in model.rows {
            let c = row.commit
            let hit = (isHex && c.id.hasPrefix(lower)) || c.subject.range(of: q, options: .caseInsensitive) != nil
            guard hit else { continue }
            out.append(PaletteItem(
                id: "commit:" + c.id, kind: .commit, title: c.subject,
                subtitle: "\(c.shortID) · \(c.authorName) · \(c.date.formatted(date: .abbreviated, time: .omitted))",
                icon: "smallcircle.filled.circle", score: 0,
                run: { [model] in
                    model.historyFilter = ""
                    model.sidebarSelection = .history
                    model.jump(to: c.id)
                },
                alternate: { [model] in Task { await model.checkoutDetached(c.id) } }))
            if out.count >= 30 { break }
        }
        return out
    }

    private var commands: [PaletteItem] {
        let m = model
        var list: [PaletteItem] = []
        func add(_ title: String, _ icon: String, _ shortcut: String? = nil, enabled: Bool = true, _ run: @escaping @MainActor () -> Void) {
            guard enabled else { return }
            list.append(PaletteItem(id: "cmd:" + title, kind: .command, title: title, icon: icon, shortcut: shortcut, score: 0, run: run))
        }
        let idle = m.remoteOperation == nil
        add("Fetch", "arrow.trianglehead.2.clockwise.rotate.90", "⇧⌘F", enabled: idle && m.hasRemotes) { m.fetch() }
        add("Pull", "arrow.down", "⇧⌘L", enabled: idle && m.currentBranch != nil) { m.pull() }
        add("Pull with Rebase", "arrow.down", enabled: idle && m.currentBranch != nil) { m.pull(.rebase) }
        add("Push", "arrow.up", "⇧⌘P", enabled: idle && m.currentBranch != nil) { m.push() }
        add("Force Push (with lease)", "arrow.up.to.line", enabled: idle && m.currentBranch != nil) { m.push(force: true) }
        add("New Branch…", "arrow.triangle.branch", "⇧⌘N") { m.beginNewBranch() }
        add("Stash Changes…", "archivebox", "⌥⌘S", enabled: !m.changes.isEmpty) { m.showStashSheet = true }
        add("Working Copy", "square.and.pencil", "⌘1") { m.sidebarSelection = .workingCopy }
        add("History", "clock.arrow.circlepath", "⌘2") { m.sidebarSelection = .history }
        add("Filter History", "magnifyingglass", "⌘F") {
            m.sidebarSelection = .history
            m.focusFilterToken += 1
        }
        add("Show Activity", "list.bullet.rectangle", "⌥⌘L") { m.showActivity = true }
        add("Refresh", "arrow.clockwise", "⌘R") { Task { await m.refresh() } }
        if let h = m.hosted {
            add("Open Repository on \(h.host.rawValue)", "safari") { m.openWeb(h.web) }
            if let ref = m.currentRef, let b = m.hostedBranch(for: ref) {
                add("Create \(h.host == .gitlab ? "Merge" : "Pull") Request for “\(ref.name)”", "arrow.triangle.pull") {
                    m.openWeb(h.newPullRequest(from: b))
                }
            }
        }
        add("Copy HEAD SHA", "doc.on.doc") {
            Task {
                if let id = await m.repo?.headID() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(id, forType: .string)
                }
            }
        }
        return list
    }
}
