import AppKit
import GroveCore
import SwiftUI

/// History list on a view-based NSTableView: cell reuse keeps 100k+ commits
/// smooth, and rows are appended in batches while `git log` streams.
struct CommitTable: NSViewRepresentable {
    let model: RepoModel
    // Passed explicitly so SwiftUI re-runs updateNSView when they change.
    let rowCount: Int
    let generation: Int
    let selectedID: String?
    let scrollToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .fullWidth
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 0)  // graph lines must touch between rows
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.gridStyleMask = []

        for (id, title, width) in [
            (Column.description, "Description", 520.0),
            (Column.author, "Author", 150.0),
            (Column.date, "Date", 140.0),
            (Column.sha, "Commit", 80.0),
        ] {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = id == Column.description ? 200 : 50
            table.addTableColumn(c)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.model = model
        guard let table = c.table else { return }
        if c.generation != generation {
            c.generation = generation
            c.count = rowCount
            table.reloadData()
        } else if c.count != rowCount {
            c.count = rowCount
            table.noteNumberOfRowsChanged()
        }
        if let id = selectedID, let row = model.displayIndex(of: id), row < c.count {
            if table.selectedRow != row {
                c.isSyncingSelection = true
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                c.isSyncingSelection = false
            }
            if c.scrollToken != scrollToken {
                c.scrollToken = scrollToken
                table.scrollRowToVisible(row)
            }
        } else if selectedID == nil, table.selectedRow >= 0 {
            table.deselectAll(nil)
        }
    }

    enum Column {
        static let description = NSUserInterfaceItemIdentifier("description")
        static let author = NSUserInterfaceItemIdentifier("author")
        static let date = NSUserInterfaceItemIdentifier("date")
        static let sha = NSUserInterfaceItemIdentifier("sha")
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var model: RepoModel
        weak var table: NSTableView?
        var count = 0
        var generation = -1
        var scrollToken = 0
        var isSyncingSelection = false

        static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f
        }()

        init(model: RepoModel) {
            self.model = model
        }

        func numberOfRows(in tableView: NSTableView) -> Int { count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, row < model.displayCount else { return nil }
            let item = model.displayRow(row)
            if id == Column.description {
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CommitGraphCell
                    ?? CommitGraphCell(identifier: id)
                cell.showsGraph = !model.isFiltering
                cell.labels = model.decorations[item.id] ?? []
                cell.row = item
                return cell
            }
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TextCell ?? TextCell(identifier: id)
            switch id {
            case Column.author:
                cell.set(item.commit.authorName, secondary: false)
                cell.toolTip = item.commit.authorEmail
            case Column.date:
                cell.set(Self.dateFormatter.string(from: item.commit.date), secondary: true)
            default:
                cell.set(item.commit.shortID, secondary: true, monospaced: true)
            }
            return cell
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, table.clickedRow >= 0, table.clickedRow < model.displayCount else { return }
            let commit = model.displayRow(table.clickedRow).commit
            func item(_ title: String, _ action: @escaping @MainActor () -> Void) {
                let i = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = MenuAction(action)
                menu.addItem(i)
            }
            let model = self.model
            let branch = model.currentBranch
            item("New Branch Here…") {
                model.branchSheet = .create(startPoint: commit.id, label: "\(commit.shortID) “\(commit.subject)”")
            }
            item("New Tag Here…") { model.tagSheet = commit }
            item("Check Out Detached") { Task { await model.checkoutDetached(commit.id) } }
            menu.addItem(.separator())
            item(branch.map { "Cherry-Pick onto “\($0)”" } ?? "Cherry-Pick") { Task { await model.cherryPick(commit) } }
            item("Revert Commit") { Task { await model.revert(commit) } }
            if let branch, model.operation == nil {
                item("Merge into “\(branch)”") { Task { await model.merge(commit.id) } }
                item("Rebase “\(branch)” onto Here") { Task { await model.rebase(onto: commit.id) } }
                item("Interactive Rebase of Later Commits…") { model.rebaseBase = commit }
            }
            let reset = NSMenuItem(title: branch.map { "Reset “\($0)” to Here" } ?? "Reset HEAD to Here", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (mode, title) in [(Repository.ResetMode.soft, "Soft — keep changes staged"),
                                  (.mixed, "Mixed — keep changes unstaged"),
                                  (.hard, "Hard — discard all changes…")] {
                let i = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = MenuAction { model.pendingReset = (commit, mode) }
                sub.addItem(i)
            }
            reset.submenu = sub
            menu.addItem(reset)
            menu.addItem(.separator())
            item("Copy SHA") { Self.copy(commit.id) }
            item("Copy Subject") { Self.copy(commit.subject) }
        }

        @objc private func runMenuAction(_ sender: NSMenuItem) {
            (sender.representedObject as? MenuAction)?.run()
        }

        static func copy(_ s: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let table else { return }
            let row = table.selectedRow
            model.selectedCommitID = row >= 0 && row < model.displayCount ? model.displayRow(row).id : nil
        }
    }
}

final class TextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, secondary: Bool, monospaced: Bool = false) {
        label.stringValue = text
        label.font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
    }
}

/// Draws graph lanes, ref badges and the subject in one pass — no subviews,
/// so scrolling stays cheap.
final class CommitGraphCell: NSTableCellView {
    var row: CommitRow? {
        didSet { needsDisplay = true; toolTip = row?.commit.subject }
    }
    /// Off while filtering: lanes of a filtered list would be misleading.
    var showsGraph = true
    var labels: [RefLabel] = []

    static let laneWidth: CGFloat = 14
    static let leftPad: CGFloat = 10
    static let palette: [NSColor] = [
        .systemBlue, .systemPink, .systemGreen, .systemOrange, .systemPurple,
        .systemTeal, .systemRed, .systemYellow, .systemIndigo, .systemBrown,
    ]

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    private static func color(_ i: Int) -> NSColor { palette[i % palette.count] }
    private static func x(_ lane: Int) -> CGFloat { leftPad + CGFloat(lane) * laneWidth }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let g = row.graph
        let h = bounds.height
        let mid = (h / 2).rounded()

        func stroke(_ s: GraphSegment, y0: CGFloat, y1: CGFloat) {
            let p = NSBezierPath()
            let a = NSPoint(x: Self.x(s.from), y: y0)
            let b = NSPoint(x: Self.x(s.to), y: y1)
            p.move(to: a)
            if s.from == s.to {
                p.line(to: b)
            } else {
                let dy = (y1 - y0) * 0.6
                p.curve(to: b, controlPoint1: NSPoint(x: a.x, y: a.y + dy), controlPoint2: NSPoint(x: b.x, y: b.y - dy))
            }
            p.lineWidth = 2
            p.lineCapStyle = .round
            Self.color(s.color).setStroke()
            p.stroke()
        }
        let emphasized = backgroundStyle == .emphasized
        var cursor: CGFloat = 8
        if showsGraph {
            for s in g.top { stroke(s, y0: 0, y1: mid) }
            for s in g.bottom { stroke(s, y0: mid, y1: h) }
            drawNode(row, g, mid: mid)
            cursor = Self.x(g.width - 1) + Self.laneWidth / 2 + 8
        }
        drawLabels(row, cursor: cursor, mid: mid, emphasized: emphasized)
    }

    private func drawNode(_ row: CommitRow, _ g: GraphRow, mid: CGFloat) {
        let r: CGFloat = row.commit.isMerge ? 3.5 : 4.5
        let dot = NSBezierPath(ovalIn: NSRect(x: Self.x(g.lane) - r, y: mid - r, width: r * 2, height: r * 2))
        if row.commit.isMerge {
            NSColor.textBackgroundColor.setFill()
            dot.fill()
            dot.lineWidth = 2
            Self.color(g.color).setStroke()
            dot.stroke()
        } else {
            Self.color(g.color).setFill()
            dot.fill()
        }
    }

    private func drawLabels(_ row: CommitRow, cursor start: CGFloat, mid: CGFloat, emphasized: Bool) {
        var cursor = start

        for ref in labels {
            cursor = drawBadge(ref, at: cursor, mid: mid, emphasized: emphasized) + 4
        }

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: emphasized ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
            .paragraphStyle: para,
        ]
        let subject = NSAttributedString(string: row.commit.subject, attributes: attrs)
        let size = subject.size()
        let rect = NSRect(x: cursor, y: mid - size.height / 2, width: max(0, bounds.width - cursor - 4), height: size.height)
        subject.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawBadge(_ ref: RefLabel, at x: CGFloat, mid: CGFloat, emphasized: Bool) -> CGFloat {
        let tint: NSColor = switch ref.kind {
        case .branch: ref.isCurrent ? .controlAccentColor : .systemGreen
        case .remote: .systemGray
        case .tag: .systemOrange
        case .head: .systemRed
        }
        let font = NSFont.systemFont(ofSize: 11, weight: ref.isCurrent ? .bold : .medium)
        let text = NSAttributedString(string: ref.name, attributes: [
            .font: font,
            .foregroundColor: emphasized ? NSColor.white : tint.blended(withFraction: 0.35, of: .labelColor) ?? tint,
        ])
        let size = text.size()
        let rect = NSRect(x: x, y: mid - 9, width: size.width + 12, height: 18)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        (emphasized ? NSColor.white.withAlphaComponent(0.2) : tint.withAlphaComponent(ref.isCurrent ? 0.28 : 0.16)).setFill()
        path.fill()
        if ref.isCurrent {
            path.lineWidth = 1
            tint.withAlphaComponent(0.7).setStroke()
            path.stroke()
        }
        text.draw(at: NSPoint(x: rect.minX + 6, y: mid - size.height / 2))
        return rect.maxX
    }
}

@MainActor
final class MenuAction: NSObject {
    let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
}
