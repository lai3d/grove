import Foundation

public struct BlameLine: Sendable, Hashable {
    public let commitID: String
    public let lineNumber: Int
    public let content: String
    public let author: String
    public let date: Date
    public let summary: String
    /// Path in that commit, when the line came from a renamed / copied file.
    public let originalPath: String?

    public var isUncommitted: Bool { commitID.allSatisfy { $0 == "0" } }
}

/// Parses `git blame --porcelain`: commit headers are printed only the first time
/// a commit appears, so they are cached by id.
public enum BlameParser {
    public static func parse(_ text: String) -> [BlameLine] {
        struct Info { var author = "", time = 0.0, summary = "", filename: String? }
        var infos: [String: Info] = [:]
        var out: [BlameLine] = []
        var current: String?
        var finalLine = 0
        var pending = Info()

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("\t") {
                guard let id = current else { continue }
                if infos[id] == nil { infos[id] = pending }
                let info = infos[id]!
                out.append(BlameLine(commitID: id, lineNumber: finalLine, content: String(raw.dropFirst()),
                                     author: info.author, date: Date(timeIntervalSince1970: info.time),
                                     summary: info.summary, originalPath: info.filename))
                current = nil
                continue
            }
            let parts = raw.split(separator: " ", maxSplits: 1)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            if key.count == 40 || key.count == 64, key.allSatisfy(\.isHexDigit) {
                // "<sha> <orig> <final> [<count>]"
                let id = String(key)
                current = id
                finalLine = value.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? finalLine + 1
                pending = infos[id] ?? Info()
                continue
            }
            switch key {
            case "author": pending.author = value
            case "author-time": pending.time = Double(value) ?? 0
            case "summary": pending.summary = value
            case "filename": pending.filename = value
            default: break
            }
            if let id = current, infos[id] != nil { infos[id] = pending }
        }
        return out
    }
}
