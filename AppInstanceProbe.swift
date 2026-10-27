import Foundation
import CoreFoundation
import Darwin

/// Disposable-process acceptance harness. Never linked into the delivered application.
@main struct AppInstanceProbe {
    static func append(_ value: String, to url: URL) {
        let fd = Darwin.open(url.path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
        guard fd >= 0 else { exit(3) }; defer { Darwin.close(fd) }
        let bytes = Array((value + "\n").utf8); _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 6, args[2].hasPrefix("local.codex.inbox.tests.") else { exit(3) }
        let directory = URL(fileURLWithPath: args[1]), namespace = args[2], mode = args[3]
        let duration = Double(args[4])!, delay = Double(args[5])!
        if mode == "invalid" {
            guard let port = CFMessagePortCreateRemote(nil, AppInstanceOwner.portName(namespace: namespace) as CFString) else { exit(3) }
            for (message, text) in [(Int32(1), "not-a-UUID"), (Int32(99), UUID().uuidString)] {
                var answer: Unmanaged<CFData>?
                _ = CFMessagePortSendRequest(port, message, Data(text.utf8) as CFData, 0.2, 0.2, CFRunLoopMode.defaultMode.rawValue, &answer)
                if let answer, !(answer.takeRetainedValue() as Data).isEmpty { exit(3) }
            }
            print("REJECTED"); return
        }
        if mode == "legacy" {
            let fd = Darwin.open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { exit(3) }
            print("LEGACY"); fflush(stdout); usleep(UInt32(duration * 1_000_000)); Darwin.close(fd); return
        }
        do {
            let claim = try AppInstanceOwner.claim(directory: directory, namespace: namespace, explicitOpen: mode != "background", timeout: 0.6) {
                append("open", to: directory.appendingPathComponent("requests.log"))
            }
            switch claim {
            case .existing: print("EXISTING")
            case .owner(let owner):
                guard fcntl(owner.descriptor, F_GETFD) & FD_CLOEXEC != 0 else { exit(3) }
                append("services", to: directory.appendingPathComponent("services.log"))
                print("OWNER"); fflush(stdout)
                if delay > 0 { usleep(UInt32(delay * 1_000_000)) }
                let end = ProcessInfo.processInfo.systemUptime + duration
                while ProcessInfo.processInfo.systemUptime < end { CFRunLoopRunInMode(.defaultMode, 0.03, true) }
                owner.close()
            }
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(2) }
    }
}
