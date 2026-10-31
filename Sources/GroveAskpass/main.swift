// GIT_ASKPASS / SSH_ASKPASS helper: forwards the prompt to the running Grove app
// and prints its answer. Exit status 1 = cancelled.
import Foundation

let env = ProcessInfo.processInfo.environment
guard let path = env["GROVE_ASKPASS_SOCKET"], let token = env["GROVE_ASKPASS_TOKEN"] else { exit(1) }
let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
let hint = env["SSH_ASKPASS_PROMPT"] ?? ""

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(1) }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: bytes)
    raw[bytes.count] = 0
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else { exit(1) }

var message = Data()
for part in [token, prompt, hint] {
    message.append(contentsOf: Array(part.utf8))
    message.append(0)
}
message.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
shutdown(fd, SHUT_WR)

var reply = Data()
var buf = [UInt8](repeating: 0, count: 4096)
while true {
    let n = read(fd, &buf, buf.count)
    if n <= 0 { break }
    reply.append(contentsOf: buf[0..<n])
}
close(fd)
guard reply.first == UInt8(ascii: "1") else { exit(1) }
FileHandle.standardOutput.write(reply.dropFirst() + Data("\n".utf8))
exit(0)
