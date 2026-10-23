// tether-askpass: an SSH_ASKPASS helper.
//
// ssh runs this program with the prompt as its first argument and reads the answer from stdout.
// We forward the prompt to the running Tether app over a private Unix socket and print its reply.
import Foundation

let env = ProcessInfo.processInfo.environment
guard let socketPath = env["TETHER_ASKPASS_SOCKET"], let token = env["TETHER_ASKPASS_TOKEN"] else {
    FileHandle.standardError.write(Data("tether-askpass: not started by Tether\n".utf8))
    exit(1)
}
let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(1) }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
guard socketPath.utf8.count < maxLen else { exit(1) }
withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
    ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { _ = strncpy($0, socketPath, maxLen - 1) }
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else { exit(1) }

var request = try! JSONSerialization.data(withJSONObject: ["token": token, "prompt": prompt])
request.append(0x0a)
_ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

var response = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while true {
    let n = read(fd, &buffer, buffer.count)
    if n <= 0 { break }
    response.append(contentsOf: buffer[0..<n])
    if response.contains(0x0a) { break }
}
close(fd)

guard let obj = try? JSONSerialization.jsonObject(with: response.prefix(while: { $0 != 0x0a })) as? [String: Any],
      obj["ok"] as? Bool == true, let answer = obj["answer"] as? String else {
    exit(1)
}
FileHandle.standardOutput.write(Data((answer + "\n").utf8))
exit(0)
