import AppKit

/// Construct a launch request without opening or activating any application.
/// Kept separate so tests can verify routing without disturbing the desktop.
struct TaskLaunch: Equatable, Sendable {
    let url: URL
    static let bundleID = "com.openai.codex"

    init?(thread: String, host: String) {
        guard !thread.isEmpty, thread != "new", !host.isEmpty,
              thread.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/" + thread
        if host != "local" { components.queryItems = [URLQueryItem(name: "hostId", value: host)] }
        guard let url = components.url else { return nil }
        self.url = url
    }

    func configuration() -> NSWorkspace.OpenConfiguration {
        let config = NSWorkspace.OpenConfiguration()
        // Use the app's OS URL handler. Starting another full Codex process
        // against the same profile exits before it can load the task.
        config.createsNewApplicationInstance = false
        config.arguments = []
        config.activates = true // Only called after the user clicks an alert.
        config.promptsUserIfNeeded = false
        config.addsToRecentItems = false
        return config
    }

    static func acceptsApplication(bundleID: String?, terminated: Bool) -> Bool {
        bundleID == Self.bundleID && !terminated
    }
}
