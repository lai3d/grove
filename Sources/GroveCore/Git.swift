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
public struct Git: Sendable {
    public let executable: URL

    public init(executable: URL = Git.defaultExecutable()) {
        self.executable = executable
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
        try box.process.run()
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
        guard okExitCodes.contains(status) else {
            throw GitError(arguments: args, exitCode: status, stderr: String(decoding: errData.data, as: UTF8.self))
        }
        return data
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
                do { try box.process.run() } catch { cont.finish(throwing: error); return }
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
    init(process: Process) { self.process = process }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
