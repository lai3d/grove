import AppKit
import SwiftUI

/// Read-only unified-diff viewer on TextKit 2 (NSTextView handles very long
/// documents far better than SwiftUI Text).
struct DiffView: NSViewRepresentable {
    let text: String

    static let maxCharacters = 3_000_000

    final class Coordinator {
        var shown: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.backgroundColor = .textBackgroundColor
        // No wrapping: diffs read best with horizontal scrolling.
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.shown != text, let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.shown = text
        tv.textStorage?.setAttributedString(Self.highlight(text))
        tv.scroll(.zero)
    }

    static func highlight(_ raw: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        var text = raw
        var truncated = false
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters))
            truncated = true
        }
        if text.isEmpty {
            return NSAttributedString(string: "", attributes: [.font: font])
        }
        let out = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        let added = NSColor.systemGreen.withAlphaComponent(0.16)
        let removed = NSColor.systemRed.withAlphaComponent(0.16)
        let ns = text as NSString
        var inHeader = true
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, lineRange, enclosing, _ in
            let first = lineRange.length > 0 ? ns.character(at: lineRange.location) : 0
            let line = { ns.substring(with: lineRange) }
            switch first {
            case 0x64 where line().hasPrefix("diff "):  // d
                inHeader = true
                out.addAttributes([.font: bold, .foregroundColor: NSColor.secondaryLabelColor], range: lineRange)
            case 0x40 where line().hasPrefix("@@"):  // @
                inHeader = false
                out.addAttributes([.foregroundColor: NSColor.systemBlue,
                                   .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.07)], range: enclosing)
            case _ where inHeader:
                out.addAttributes([.font: bold, .foregroundColor: NSColor.secondaryLabelColor], range: lineRange)
            case 0x2B:  // +
                out.addAttribute(.backgroundColor, value: added, range: enclosing)
            case 0x2D:  // -
                out.addAttribute(.backgroundColor, value: removed, range: enclosing)
            case 0x5C:  // "\ No newline at end of file"
                out.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: lineRange)
            default:
                break
            }
        }
        if truncated {
            out.append(NSAttributedString(string: "\n… diff truncated (too large to display)\n",
                                          attributes: [.font: bold, .foregroundColor: NSColor.systemOrange]))
        }
        return out
    }
}
