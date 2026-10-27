import Foundation
import CoreFoundation
import Darwin

enum AppInstanceError: LocalizedError {
    case ownership(String), handoff
    var errorDescription: String? {
        switch self {
        case .ownership(let reason): return "Codex Inbox could not establish exclusive ownership. No collector was started. " + reason
        case .handoff: return "Another Codex Inbox owns the inbox, but did not acknowledge the open request. No second collector was started. If it is an older build, quit and reopen Codex Inbox from Applications."
        }
    }
}

enum AppInstanceClaim {
    case owner(AppInstanceOwner)
    case existing
}

/// The persistent flock is the authority. The user-scoped port accepts only an Open request.
/// Neither the lock nor the port identity depends on the executable's install path.
final class AppInstanceOwner {
    static let identity = "local.codex.inbox"
    private(set) var descriptor: Int32
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    private let loop: CFRunLoop
    private let onOpen: () -> Void
    private var received: [UUID] = []

    static func portName(namespace: String) -> String { namespace + ".user-\(getuid()).open-v1" }
    static func claim(directory: URL, namespace: String = identity, explicitOpen: Bool,
                      timeout: Double = 2.5, onOpen: @escaping () -> Void) throws -> AppInstanceClaim {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AppInstanceError.ownership(String(cString: strerror(errno))) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(fd); throw AppInstanceError.ownership("The lock is not a regular file owned by this user.")
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            do { return .owner(try AppInstanceOwner(descriptor: fd, namespace: namespace, onOpen: onOpen)) }
            catch { Darwin.close(fd); throw error }
        }
        let failure = errno; Darwin.close(fd)
        guard failure == EWOULDBLOCK || failure == EAGAIN else { throw AppInstanceError.ownership(String(cString: strerror(failure))) }
        guard explicitOpen else { return .existing }
        guard forwardOpen(namespace: namespace, timeout: timeout) else { throw AppInstanceError.handoff }
        return .existing
    }
    private init(descriptor: Int32, namespace: String, onOpen: @escaping () -> Void) throws {
        self.descriptor = descriptor; self.onOpen = onOpen; loop = CFRunLoopGetCurrent()
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let port = CFMessagePortCreateLocal(nil, Self.portName(namespace: namespace) as CFString, { _, message, data, info in
            guard let info else { return nil }
            return Unmanaged<AppInstanceOwner>.fromOpaque(info).takeUnretainedValue().accept(message: message, data: data)
        }, &context, nil) else {
            self.descriptor = -1
            throw AppInstanceError.ownership("The local open-request endpoint is unavailable.")
        }
        guard let source = CFMessagePortCreateRunLoopSource(nil, port, 0) else {
            CFMessagePortInvalidate(port); self.descriptor = -1
            throw AppInstanceError.ownership("The local open-request endpoint could not start.")
        }
        self.port = port; self.source = source
        CFRunLoopAddSource(loop, source, .commonModes)
    }
    private func accept(message: Int32, data: CFData?) -> Unmanaged<CFData>? {
        guard descriptor >= 0, message == 1, let data, CFDataGetLength(data) == 36,
              let string = String(data: data as Data, encoding: .utf8), let id = UUID(uuidString: string) else { return nil }
        if !received.contains(id) {
            received.append(id); if received.count > 64 { received.removeFirst() }
            onOpen()
        }
        return Unmanaged.passRetained(Data("open-accepted-v1".utf8) as CFData)
    }
    static func forwardOpen(namespace: String, timeout: Double) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, min(timeout, 3))
        let payload = Data(UUID().uuidString.utf8) as CFData
        repeat {
            if let remote = CFMessagePortCreateRemote(nil, portName(namespace: namespace) as CFString) {
                var answer: Unmanaged<CFData>?
                let remaining = max(0.001, min(0.15, deadline - ProcessInfo.processInfo.systemUptime))
                let result = CFMessagePortSendRequest(remote, 1, payload, remaining, remaining, CFRunLoopMode.defaultMode.rawValue, &answer)
                let reply = answer?.takeRetainedValue() as Data?
                if result == kCFMessagePortSuccess && reply == Data("open-accepted-v1".utf8) { return true }
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            usleep(20_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
    func close() {
        if let source { CFRunLoopRemoveSource(loop, source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
        source = nil; port = nil
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        // Never unlink a lock: a contender might already hold an open reference to its inode.
    }
    deinit { close() }
}
