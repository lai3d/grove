import Foundation

/// A small, dependency-free highlighter: keywords, strings, comments, numbers and type-like
/// identifiers for common languages. Works line by line; `State` carries block comments and
/// multi-line strings from one line to the next.
public struct SyntaxHighlighter: Sendable {
    public enum State: Sendable, Hashable {
        case normal
        case blockComment
        /// Inside a multi-line string opened by this delimiter (`"""`, `\'\'\'`, backtick).
        case string(String)
    }

    public enum Kind: Sendable { case keyword, string, comment, number, type }
    public struct Token: Sendable, Hashable {
        public let range: NSRange
        public let kind: Kind
    }

    let keywords: Set<String>
    let lineComments: [String]
    let blockComment: (String, String)?
    let quotes: Set<Character>
    let multiline: [String]
    let capitalizedAreTypes: Bool

    public static func forPath(_ path: String) -> SyntaxHighlighter? {
        let ext = (path as NSString).pathExtension.lowercased()
        let name = (path as NSString).lastPathComponent
        switch ext {
        case "swift":
            return .init(kw: "actor any as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate for func guard if import in init inout internal is let lazy mutating nil nonisolated open operator override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while", line: ["//"], block: ("/*", "*/"), multiline: ["\"\"\""])
        case "js", "jsx", "ts", "tsx", "mjs", "cjs":
            return .init(kw: "as async await break case catch class const continue debugger default delete do else enum export extends false finally for from function if implements import in instanceof interface let new null of private protected public readonly return static super switch this throw true try type typeof undefined var void while with yield", line: ["//"], block: ("/*", "*/"), quotes: ["\"", "'", "`"], multiline: ["`"])
        case "py":
            return .init(kw: "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return self try while with yield", line: ["#"], block: nil, quotes: ["\"", "'"], multiline: ["\"\"\"", "\'\'\'"])
        case "go":
            return .init(kw: "break case chan const continue default defer else fallthrough false for func go goto if import interface map nil package range return select struct switch true type var", line: ["//"], block: ("/*", "*/"), quotes: ["\"", "'", "`"], multiline: ["`"])
        case "rs":
            return .init(kw: "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while", line: ["//"], block: ("/*", "*/"))
        case "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "kts", "cs", "scala", "dart":
            return .init(kw: "abstract auto bool break case catch char class const continue default delete do double else enum extern false final float for fun if implements import in inline int interface internal is long namespace new nil null object override package private protected public return self short signed sizeof static struct super switch template this throw throws true try typedef typename union unsigned val var virtual void volatile when while", line: ["//"], block: ("/*", "*/"))
        case "rb":
            return .init(kw: "alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield", line: ["#"], block: nil, quotes: ["\"", "'"])
        case "sh", "bash", "zsh":
            return .init(kw: "case do done elif else esac export fi for function if in local readonly return set shift then until while", line: ["#"], block: nil, quotes: ["\"", "'"], types: false)
        case "json":
            return .init(kw: "true false null", line: [], block: nil, quotes: ["\""], types: false)
        case "yml", "yaml", "toml":
            return .init(kw: "true false null yes no", line: ["#"], block: nil, quotes: ["\"", "'"], types: false)
        case "sql":
            return .init(kw: "select from where insert into update delete create table alter drop index join left right inner outer on group by order having limit and or not null as values set primary key", line: ["--"], block: ("/*", "*/"), quotes: ["'", "\""], types: false, caseInsensitive: true)
        default:
            if name == "Makefile" || name == "Dockerfile" {
                return .init(kw: "FROM RUN CMD COPY ADD ENV ARG WORKDIR EXPOSE ENTRYPOINT USER LABEL VOLUME", line: ["#"], block: nil, quotes: ["\"", "'"], types: false)
            }
            return nil
        }
    }

    init(kw: String, line: [String], block: (String, String)?, quotes: Set<Character> = ["\""], types: Bool = true,
         caseInsensitive: Bool = false, multiline: [String] = []) {
        self.multiline = multiline
        let words = kw.split(separator: " ").map(String.init)
        keywords = Set(caseInsensitive ? words + words.map { $0.uppercased() } : words)
        lineComments = line
        blockComment = block
        self.quotes = quotes
        capitalizedAreTypes = types
    }

    public func tokens(_ line: String) -> [Token] {
        var state = State.normal
        return tokens(line, state: &state)
    }

    /// Tokens of one line, starting in `state`; on return `state` is the state at the end of the line.
    public func tokens(_ line: String, state: inout State) -> [Token] {
        let u = Array(line.utf16)
        var out: [Token] = []
        var i = 0
        func starts(_ s: String, at k: Int) -> Bool {
            let p = Array(s.utf16)
            return k + p.count <= u.count && Array(u[k..<k + p.count]) == p
        }
        func isWord(_ c: UInt16) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
        }
        // Continue a construct opened on an earlier line.
        switch state {
        case .blockComment:
            guard let (_, close) = blockComment else { state = .normal; break }
            var j = 0
            while j < u.count && !starts(close, at: j) { j += 1 }
            if j < u.count {
                j += close.utf16.count
                state = .normal
            }
            out.append(Token(range: NSRange(location: 0, length: min(j, u.count)), kind: .comment))
            i = j
        case .string(let delimiter):
            var j = 0
            while j < u.count && !starts(delimiter, at: j) { j += (u[j] == 92 ? 2 : 1) }
            if j < u.count {
                j += delimiter.utf16.count
                state = .normal
            }
            j = min(j, u.count)
            out.append(Token(range: NSRange(location: 0, length: j), kind: .string))
            i = j
        case .normal:
            break
        }
        while i < u.count {
            if let delimiter = multiline.first(where: { starts($0, at: i) }) {
                var j = i + delimiter.utf16.count
                while j < u.count && !starts(delimiter, at: j) { j += (u[j] == 92 ? 2 : 1) }
                if j < u.count {
                    j += delimiter.utf16.count
                } else {
                    state = .string(delimiter)
                }
                j = min(j, u.count)
                out.append(Token(range: NSRange(location: i, length: j - i), kind: .string))
                i = j
                continue
            }
            if let lc = lineComments.first(where: { starts($0, at: i) }) {
                _ = lc
                out.append(Token(range: NSRange(location: i, length: u.count - i), kind: .comment))
                break
            }
            if let (open, close) = blockComment, starts(open, at: i) {
                var j = i + open.utf16.count
                while j < u.count && !starts(close, at: j) { j += 1 }
                if j >= u.count { state = .blockComment }
                j = min(u.count, j + close.utf16.count)
                out.append(Token(range: NSRange(location: i, length: j - i), kind: .comment))
                i = j
                continue
            }
            let c = u[i]
            if c < 128, quotes.contains(Character(UnicodeScalar(UInt8(c)))) {
                var j = i + 1
                while j < u.count && u[j] != c { j += (u[j] == 92 ? 2 : 1) }  // skip \x
                j = min(u.count, j + 1)
                out.append(Token(range: NSRange(location: i, length: j - i), kind: .string))
                i = j
                continue
            }
            if isWord(c) {
                var j = i
                while j < u.count && isWord(u[j]) { j += 1 }
                let word = String(utf16CodeUnits: Array(u[i..<j]), count: j - i)
                if keywords.contains(word) {
                    out.append(Token(range: NSRange(location: i, length: j - i), kind: .keyword))
                } else if c >= 48 && c <= 57 {
                    out.append(Token(range: NSRange(location: i, length: j - i), kind: .number))
                } else if capitalizedAreTypes, c >= 65 && c <= 90, j - i > 1 {
                    out.append(Token(range: NSRange(location: i, length: j - i), kind: .type))
                }
                i = j
                continue
            }
            i += 1
        }
        return out
    }
}

extension SyntaxHighlighter {
    /// Tokens for every line of a hunk. The old side (context + removed lines) and the new side
    /// (context + added lines) each carry their own multi-line state.
    public func tokens(for hunk: DiffHunk) -> [[Token]] {
        var oldState = State.normal, newState = State.normal
        return hunk.lines.map { line in
            switch line.kind {
            case .removed:
                return tokens(line.text, state: &oldState)
            case .added:
                return tokens(line.text, state: &newState)
            case .context:
                var s = newState
                let t = tokens(line.text, state: &s)
                newState = s
                _ = tokens(line.text, state: &oldState)
                return t
            }
        }
    }
}

