import AppKit
import GroveCore
import SwiftUI

enum DiffMode: String, CaseIterable { case unified, split }

/// Loads the before / after versions of a binary file (for image diffs).
typealias BlobPair = @Sendable () async -> (old: Data?, new: Data?)

/// Diff pane for commits and stashes: rich unified / side-by-side view with word-level and
/// syntax highlighting, image diff for binary images, plain text for huge diffs.
struct DiffPane: View {
    let text: String
    let path: String?
    var blobs: BlobPair?
    @AppStorage("diffMode") private var mode: DiffMode = .unified

    static let maxRichLines = 8000

    var body: some View {
        let diff = DiffParser.parse(text).first
        VStack(spacing: 0) {
            if let path {
                HStack {
                    Text(path).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Picker("", selection: $mode) {
                        Text("Unified").tag(DiffMode.unified)
                        Text("Split").tag(DiffMode.split)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
            if let diff, let lfs = diff.lfsChange {
                LFSDiffView(old: lfs.old, new: lfs.new)
            } else if let diff, diff.isBinary, let path, ImageDiffView.isImage(path), let blobs {
                ImageDiffView(blobs: blobs).id(text)
            } else if let diff, !diff.hunks.isEmpty, diff.hunks.reduce(0, { $0 + $1.lines.count }) <= Self.maxRichLines {
                RichDiffView(diff: diff, path: path ?? diff.newPath ?? diff.oldPath ?? "", mode: mode)
                    .id("\(mode.rawValue)\u{0}\(text)")  // LazyVStack keeps stale rows otherwise
            } else {
                DiffView(text: text)
            }
        }
    }
}

/// Highlighting shared by the rich views and the working-copy hunk view.
struct DiffStyler {
    let highlighter: SyntaxHighlighter?

    init(path: String) { highlighter = SyntaxHighlighter.forPath(path) }

    func text(_ line: DiffLine, changed: [NSRange]) -> AttributedString {
        let ns = NSMutableAttributedString(string: line.text.isEmpty ? " " : line.text)
        if let highlighter {
            for t in highlighter.tokens(line.text) {
                ns.addAttribute(.foregroundColor, value: Self.color(t.kind), range: t.range)
            }
        }
        let strong: NSColor = line.kind == .added ? .systemGreen.withAlphaComponent(0.38) : .systemRed.withAlphaComponent(0.34)
        for r in changed where NSMaxRange(r) <= ns.length {
            ns.addAttribute(.backgroundColor, value: strong, range: r)
        }
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(line.text)
    }

    static func color(_ kind: SyntaxHighlighter.Kind) -> NSColor {
        switch kind {
        case .keyword: .systemPink
        case .string: .systemRed
        case .comment: .systemGray
        case .number: .systemBlue
        case .type: .systemPurple
        }
    }

    /// Word-level change ranges for every paired removed / added line of a hunk.
    static func wordRanges(_ hunk: DiffHunk) -> [Int: [NSRange]] {
        var out: [Int: [NSRange]] = [:]
        for (a, b) in hunk.pairs where hunk.lines[a].kind == .removed {
            let r = WordDiff.ranges(old: hunk.lines[a].text, new: hunk.lines[b].text)
            out[a] = r.old
            out[b] = r.new
        }
        return out
    }
}

struct RichDiffView: View {
    let diff: FileDiff
    let mode: DiffMode
    private let styler: DiffStyler
    private let words: [[Int: [NSRange]]]

    init(diff: FileDiff, path: String, mode: DiffMode) {
        self.diff = diff
        self.mode = mode
        styler = DiffStyler(path: path)
        words = diff.hunks.map(DiffStyler.wordRanges)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(diff.hunks.indices, id: \.self) { h in
                    Section {
                        switch mode {
                        case .unified:
                            ForEach(diff.hunks[h].lines.indices, id: \.self) { i in
                                let line = diff.hunks[h].lines[i]
                                DiffLineRow(line: line, selected: false, text: styler.text(line, changed: words[h][i] ?? []))
                            }
                        case .split:
                            let rows = diff.hunks[h].splitRows
                            ForEach(rows.indices, id: \.self) { r in
                                SplitRowView(row: rows[r], styler: styler, words: words[h])
                            }
                        }
                        Spacer().frame(height: 8)
                    } header: {
                        Text(diff.hunks[h].header)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.bar)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct SplitRowView: View {
    let row: SplitRow
    let styler: DiffStyler
    let words: [Int: [NSRange]]
    @AppStorage("diffFontSize") private var diffFontSize = 12.0

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(row.left, index: row.leftIndex, number: row.left?.oldNumber)
            Divider()
            side(row.right, index: row.rightIndex, number: row.right?.newNumber)
        }
    }

    private func side(_ line: DiffLine?, index: Int?, number: Int?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: diffFontSize - 1, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 6)
            if let line, let index {
                Text(styler.text(line, changed: words[index] ?? []))
                    .font(.system(size: diffFontSize, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer().frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background(line))
    }

    private func background(_ line: DiffLine?) -> Color {
        guard let line else { return Color.gray.opacity(0.06) }
        switch line.kind {
        case .context: return .clear
        case .added: return .green.opacity(0.14)
        case .removed: return .red.opacity(0.14)
        }
    }
}

struct ImageDiffView: View {
    let blobs: BlobPair
    @State private var images: (old: NSImage?, new: NSImage?, oldSize: Int?, newSize: Int?)?

    static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "webp", "ico", "icns", "pdf"]

    static func isImage(_ path: String) -> Bool { extensions.contains((path as NSString).pathExtension.lowercased()) }

    var body: some View {
        Group {
            if let images {
                HStack(spacing: 0) {
                    pane("Before", images.old, images.oldSize)
                    Divider()
                    pane("After", images.new, images.newSize)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let (a, b) = await blobs()
            images = (a.flatMap(NSImage.init(data:)), b.flatMap(NSImage.init(data:)), a?.count, b?.count)
        }
    }

    private func pane(_ title: String, _ image: NSImage?, _ bytes: Int?) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .background(CheckerBoard())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("\(Int(image.size.width))×\(Int(image.size.height)) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes ?? 0), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(bytes == nil ? "No File" : "Can't Display", systemImage: "photo")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CheckerBoard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.15)))
                }
            }
        }
    }
}

struct LFSDiffView: View {
    let old: LFSPointer?
    let new: LFSPointer?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Git LFS object").font(.headline)
            HStack(spacing: 18) {
                side("Before", old)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                side("After", new)
            }
            if let o = old, let n = new {
                let delta = n.size - o.size
                Text(delta == 0 ? "Same size" : "\(delta > 0 ? "+" : "−")\(ByteCountFormatter.string(fromByteCount: abs(delta), countStyle: .file))")
                    .font(.callout).foregroundStyle(delta > 0 ? .orange : .green)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func side(_ title: String, _ p: LFSPointer?) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let p {
                Text(ByteCountFormatter.string(fromByteCount: p.size, countStyle: .file)).font(.title3.monospacedDigit())
                Text(String(p.oid.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text("—").font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 120)
    }
}
