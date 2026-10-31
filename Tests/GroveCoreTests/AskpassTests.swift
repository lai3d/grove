import Foundation
import Testing

@testable import GroveCore

@Suite struct AskpassTests {
    /// The helper binary SwiftPM built next to the test bundle.
    static var helper: URL {
        var dir = URL(fileURLWithPath: #filePath)
        while dir.lastPathComponent != "Tests" { dir.deleteLastPathComponent() }
        let build = dir.deletingLastPathComponent().appendingPathComponent(".build")
        let debug = build.appendingPathComponent("debug/grove-askpass")
        return debug
    }

    @Test func requestKinds() {
        #expect(AskpassServer.Request(prompt: "Password for 'https://u@github.com': ", hint: "").kind == .secret)
        #expect(AskpassServer.Request(prompt: "Enter passphrase for key '/Users/x/.ssh/id_ed25519': ", hint: "").kind == .secret)
        #expect(AskpassServer.Request(prompt: "Username for 'https://github.com': ", hint: "").kind == .text)
        let hostKey = AskpassServer.Request(prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])?", hint: "")
        #expect(hostKey.kind == .confirm && hostKey.confirmAnswer(true) == "yes")
        #expect(AskpassServer.Request(prompt: "Allow use of key?", hint: "confirm").kind == .confirm)
    }

    @Test func helperRoundTripThroughGit() async throws {
        let server = AskpassServer(socketPath: NSTemporaryDirectory() + "grove-askpass-test-\(UUID().uuidString.prefix(8)).sock")
        let seen = Seen()
        let env = server.register(helper: Self.helper) { req in
            seen.set(req.prompt)
            return req.kind == .secret ? "s3cret" : nil
        }
        try #require(!env.isEmpty, "helper not built at \(Self.helper.path)")

        // `git credential fill` asks through GIT_ASKPASS for anything it lacks.
        let dir = FileManager.default.temporaryDirectory
        let git = Git(environment: env.merging(["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]) { $1 })
        let out = try await git.runString(["-c", "credential.helper=", "credential", "fill"], in: dir,
                                          input: Data("protocol=https\nhost=example.com\nusername=me\n\n".utf8))
        #expect(out.contains("password=s3cret"))
        #expect(seen.value?.contains("Password for 'https://me@example.com'") == true)

        // Cancelled username prompt → git fails instead of hanging.
        await #expect(throws: GitError.self) {
            try await git.run(["-c", "credential.helper=", "credential", "fill"], in: dir,
                              input: Data("protocol=https\nhost=example.com\n\n".utf8))
        }
    }

    @Test func missingHelperDisablesAskpass() {
        let env = AskpassServer.shared.register(helper: URL(fileURLWithPath: "/nonexistent/helper")) { _ in nil }
        #expect(env.isEmpty)
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    func set(_ v: String) { lock.withLock { _value = v } }
    var value: String? { lock.withLock { _value } }
}
