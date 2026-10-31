import Foundation

public struct GitError: Error, CustomStringConvertible, Sendable {
    public let arguments: [String]
    public let exitCode: Int32
    public let stderr: String

    public var description: String {
        let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "git \(arguments.joined(separator: " ")) failed (\(exitCode))" + (msg.isEmpty ? "" : ": \(msg)")
    }
}

/// Thin runner around the `git` executable. All repository writes go through the
/// real CLI so hooks, credential helpers, signing and user config behave exactly
/// as they do in the terminal.
/// One git invocation, reported to `Git.observer` when it starts and when it ends.
public struct GitEvent: Sendable, Identifiable {
    public enum Phase: Sendable {
        case started
        case finished(exitCode: Int32, duration: TimeInterval, output: String)
        case failedToLaunch(String)
    }
    public let id: UUID
    public let arguments: [String]
    public let phase: Phase

    static let readOnlyCommands: Set<String> = [
        "status", "log", "rev-parse", "for-each-ref", "show", "diff", "diff-tree", "hash-object",
        "symbolic-ref", "check-ref-format", "cat-file", "ls-files", "rev-list", "blame", "merge-base",
    ]

    /// Queries that don't change anything (hidden from the activity log).
    public var isReadOnly: Bool {
        // Skip global `-c key=value` options.
        var args = arguments[...]
        while args.first == "-c" { args = args.dropFirst(2) }
        guard let cmd = args.first else { return true }
        let sub = args.dropFirst().first
        switch cmd {
        case "remote": return sub == nil || sub == "-v" || sub == "get-url" || sub == "show"
        case "stash": return sub == "list" || sub == "show"
        case "reflog": return sub == nil || sub == "show"
        case "branch", "tag": return sub == nil || sub == "--list" || sub == "-l"
        case "config":
            // `config key` / `config --get…` / `config --list` read; `config key value` writes.
            return args.contains { ["--get", "--get-all", "--get-regexp", "--list", "-l"].contains($0) } || args.count == 2
        default: return Self.readOnlyCommands.contains(cmd)
        }
    }
}

public struct Git: Sendable {
    public let executable: URL
    /// Called (on a background queue) for every git process Grove runs.
    public var observer: (@Sendable (GitEvent) -> Void)?

    public init(executable: URL = Git.defaultExecutable(), observer: (@Sendable (GitEvent) -> Void)? = nil) {
        self.executable = executable
        self.observer = observer
    }

    private func report(_ id: UUID, _ args: [String], _ phase: GitEvent.Phase) {
        observer?(GitEvent(id: id, arguments: args, phase: phase))
    }

    public static func defaultExecutable() -> URL {
        if let p = ProcessInfo.processInfo.environment["GROVE_GIT"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        for p in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return URL(fileURLWithPath: "/usr/bin/git")
    }

    static let baseArguments = [
        "-c", "core.quotepath=false",
        "-c", "color.ui=false",
        "-c", "log.showSignature=false",
    ]

    private func makeProcess(_ args: [String], in dir: URL) -> ProcessBox {
        let p = Process()
        p.executableURL = executable
        p.arguments = Self.baseArguments + args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        // Reads (status, diff) must not take the index lock and fight the user's terminal.
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        // Apps launched from Finder get a minimal PATH; ssh/gpg/hooks need the usual tools.
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        p.environment = env
        let box = ProcessBox(process: p)
        p.standardOutput = box.out
        p.standardError = box.err
        p.standardInput = box.input
        return box
    }

    /// Runs git to completion and returns stdout.
    public func run(_ args: [String], in dir: URL, input: Data? = nil, okExitCodes: Set<Int32> = [0]) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try self.runSync(args, in: dir, input: input, okExitCodes: okExitCodes))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func runString(_ args: [String], in dir: URL, input: Data? = nil, okExitCodes: Set<Int32> = [0]) async throws -> String {
        String(decoding: try await run(args, in: dir, input: input, okExitCodes: okExitCodes), as: UTF8.self)
    }

    private func runSync(_ args: [String], in dir: URL, input: Data?, okExitCodes: Set<Int32>) throws -> Data {
        let box = makeProcess(args, in: dir)
        let id = UUID(), start = Date()
        report(id, args, .started)
        do { try box.process.run() } catch {
            report(id, args, .failedToLaunch("\(error)"))
            throw error
        }
        let group = DispatchGroup()
        let errData = DataBox()
        group.enter()
        DispatchQueue.global().async {
            errData.data = box.err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let h = box.input.fileHandleForWriting
            if let input { try? h.write(contentsOf: input) }
            try? h.close()
            group.leave()
        }
        let data = box.out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        box.process.waitUntilExit()
        let status = box.process.terminationStatus
        let stderr = String(decoding: errData.data, as: UTF8.self)
        report(id, args, .finished(exitCode: status, duration: Date().timeIntervalSince(start), output: stderr))
        guard okExitCodes.contains(status) else {
            throw GitError(arguments: args, exitCode: status, stderr: stderr)
        }
        return data
    }

    /// Runs a long operation (fetch / push / pull…), streaming each stderr progress
    /// line (git separates updates with \r) to `progress`. Cancelling the calling
    /// task terminates git and throws `CancellationError`. Returns git's stderr+stdout text.
    public func runWithProgress(_ args: [String], in dir: URL,
                                progress: @escaping @Sendable (String) -> Void) async throws -> String {
        let box = makeProcess(args, in: dir)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let id = UUID(), start = Date()
                    report(id, args, .started)
                    do { try box.launchUnlessCancelled() } catch {
                        report(id, args, .failedToLaunch("\(error)"))
                        cont.resume(throwing: error)
                        return
                    }
                    try? box.input.fileHandleForWriting.close()
                    let group = DispatchGroup()
                    let out = DataBox()
                    group.enter()
                    DispatchQueue.global().async {
                        out.data = box.out.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    var all = Data()
                    var line = Data()
                    let h = box.err.fileHandleForReading
                    while true {
                        let chunk = h.availableData
                        if chunk.isEmpty { break }
                        all.append(chunk)
                        for b in chunk {
                            if b == 13 || b == 10 {
                                if !line.isEmpty { progress(String(decoding: line, as: UTF8.self)); line.removeAll() }
                            } else {
                                line.append(b)
                            }
                        }
                    }
                    if !line.isEmpty { progress(String(decoding: line, as: UTF8.self)) }
                    group.wait()
                    box.process.waitUntilExit()
                    let status = box.process.terminationStatus
                    // Keep only the final state of \r-updated progress lines.
                    let text = Self.collapseProgress(String(decoding: all, as: UTF8.self))
                        + String(decoding: out.data, as: UTF8.self)
                    report(id, args, .finished(exitCode: status, duration: Date().timeIntervalSince(start), output: text))
                    if box.isCancelled {
                        cont.resume(throwing: CancellationError())
                    } else if status != 0 {
                        cont.resume(throwing: GitError(arguments: args, exitCode: status, stderr: text))
                    } else {
                        cont.resume(returning: text)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    static func collapseProgress(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "\r").last.map(String.init) ?? "" }
            .joined(separator: "\n")
    }

    /// Streams stdout split on `separator` (NUL by default, for `-z` output).
    /// Cancelling the consuming task terminates the git process.
    public func records(_ args: [String], in dir: URL, separator: UInt8 = 0) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let box = makeProcess(args, in: dir)
            cont.onTermination = { reason in
                if case .cancelled = reason, box.process.isRunning { box.process.terminate() }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let id = UUID(), start = Date()
                report(id, args, .started)
                do { try box.process.run() } catch {
                    report(id, args, .failedToLaunch("\(error)"))
                    cont.finish(throwing: error)
                    return
                }
                try? box.input.fileHandleForWriting.close()
                let group = DispatchGroup()
                let errData = DataBox()
                group.enter()
                DispatchQueue.global().async {
                    errData.data = box.err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let h = box.out.fileHandleForReading
                var buf = Data()
                while true {
                    let chunk = h.availableData
                    if chunk.isEmpty { break }
                    buf.append(chunk)
                    var start = buf.startIndex
                    while let i = buf[start...].firstIndex(of: separator) {
                        cont.yield(Data(buf[start..<i]))
                        start = buf.index(after: i)
                    }
                    buf = Data(buf[start...])
                }
                if !buf.isEmpty { cont.yield(buf) }
                group.wait()
                box.process.waitUntilExit()
                let p = box.process
                report(id, args, .finished(exitCode: p.terminationStatus, duration: Date().timeIntervalSince(start),
                                           output: String(decoding: errData.data, as: UTF8.self)))
                if p.terminationStatus == 0 || p.terminationReason == .uncaughtSignal {
                    cont.finish()
                } else {
                    cont.finish(throwing: GitError(arguments: args, exitCode: p.terminationStatus,
                                                   stderr: String(decoding: errData.data, as: UTF8.self)))
                }
            }
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    let out = Pipe()
    let err = Pipe()
    let input = Pipe()
    private let lock = NSLock()
    private var cancelled = false

    init(process: Process) { self.process = process }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func launchUnlessCancelled() throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run()
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
