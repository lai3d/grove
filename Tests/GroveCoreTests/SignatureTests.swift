import Foundation
import Testing

@testable import GroveCore

@Suite struct SignatureTests {
    @Test func sshSignedAndUnsignedCommits() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grove-sign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = dir.appendingPathComponent("key").path
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", key, "-C", "signer@example.com"]
        try keygen.run()
        keygen.waitUntilExit()
        let pub = try String(contentsOfFile: key + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = dir.appendingPathComponent("allowed_signers")
        try "signer@example.com \(pub)\n".write(to: allowed, atomically: true, encoding: .utf8)

        let repoDir = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let git = Git()
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "signer@example.com"],
                     ["config", "gpg.format", "ssh"], ["config", "user.signingkey", key],
                     ["config", "gpg.ssh.allowedSignersFile", allowed.path], ["config", "commit.gpgsign", "false"]] {
            _ = try await git.run(args, in: repoDir)
        }
        try "1".write(to: repoDir.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        _ = try await git.run(["add", "."], in: repoDir)
        _ = try await git.run(["commit", "-qm", "unsigned"], in: repoDir)
        try "2".write(to: repoDir.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        _ = try await git.run(["commit", "-qam", "signed", "-S"], in: repoDir)

        let repo = try await Repository.open(repoDir)
        let signed = await repo.signature(of: "HEAD")
        #expect(signed.status == .good)
        #expect(signed.signer == "signer@example.com")
        #expect(signed.key?.hasPrefix("SHA256:") == true)
        #expect(await repo.signature(of: "HEAD~1").status == .unsigned)

        // Signer not in the allowed list → signed but can't be verified as trusted.
        try "".write(to: allowed, atomically: true, encoding: .utf8)
        let untrusted = await repo.signature(of: "HEAD")
        #expect(untrusted.status != .good && untrusted.status != .unsigned)
    }
}
