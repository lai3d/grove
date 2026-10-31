import Foundation

/// Answers `GIT_ASKPASS` / `SSH_ASKPASS` prompts in the app. git or ssh runs the
/// tiny `grove-askpass` helper, which forwards the prompt over a Unix socket to
/// this server; the server routes it (by token) to whoever started the command.
public final class AskpassServer: @unchecked Sendable {
    public struct Request: Sendable, Identifiable {
        public enum Kind: Sendable { case secret, text, confirm }
        public let id = UUID()
        public let prompt: String
        public let kind: Kind

        public init(prompt: String, hint: String) {
            self.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let p = prompt.lowercased()
            if hint == "confirm" || p.contains("(yes/no") {
                kind = .confirm
            } else if ["password", "passphrase", "token", "pin for", "pin:"].contains(where: p.contains) {
                kind = .secret
            } else {
                kind = .text
            }
        }

        /// Answer for a confirm prompt in the form the asker expects.
        public func confirmAnswer(_ yes: Bool) -> String {
            prompt.lowercased().contains("(yes/no") ? (yes ? "yes" : "no") : (yes ? "" : "no")
        }
    }

    public typealias Handler = @Sendable (Request) async -> String?

    public static let shared = AskpassServer()

    public let socketPath: String
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var listening = false

    init(socketPath: String = NSTemporaryDirectory() + "grove-askpass-\(getpid()).sock") {
        self.socketPath = socketPath
    }

    /// Registers a prompt handler; pass the returned environment to `Git`.
    public func register(helper: URL, _ handler: @escaping Handler) -> [String: String] {
        guard FileManager.default.isExecutableFile(atPath: helper.path), (try? startIfNeeded()) != nil else { return [:] }
        let token = UUID().uuidString
        lock.withLock { handlers[token] = handler }
        return [
            "GIT_ASKPASS": helper.path,
            "SSH_ASKPASS": helper.path,
            "SSH_ASKPASS_REQUIRE": "force",
            "GROVE_ASKPASS_SOCKET": socketPath,
            "GROVE_ASKPASS_TOKEN": token,
        ]
    }

    private func startIfNeeded() throws {
        try lock.withLock {
            guard !listening else { return }
            unlink(socketPath)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            var addr = Self.address(socketPath)
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard ok == 0, listen(fd, 8) == 0 else {
                close(fd)
                throw POSIXError(.EADDRINUSE)
            }
            chmod(socketPath, 0o600)
            listening = true
            Thread.detachNewThread { [self] in
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 { continue }
                    DispatchQueue.global().async { self.serve(client) }
                }
            }
        }
    }

    private func serve(_ client: Int32) {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        let parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        let handler = parts.count >= 2 ? lock.withLock { handlers[parts[0]] } : nil
        let request = Request(prompt: parts.count > 1 ? parts[1] : "", hint: parts.count > 2 ? parts[2] : "")
        Task {
            let answer = await handler?(request)
            let reply = Data((answer.map { "1" + $0 } ?? "0").utf8)
            reply.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
            close(client)
        }
    }

    static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }
}
