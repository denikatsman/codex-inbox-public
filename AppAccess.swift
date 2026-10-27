import AppKit
import Combine

struct AppAccessConfiguration: Equatable {
    var menuBar = true
    var dock = false
    var isValid: Bool { menuBar || dock }
}

/// Presentation preferences only. Changing these never starts collection or requests permission.
@MainActor final class AppAccess: ObservableObject {
    static let preferenceKey = "appAccess.v1"
    @Published private(set) var configuration: AppAccessConfiguration
    @Published var message = ""
    private let defaults: UserDefaults?
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let saved = defaults?.dictionary(forKey: Self.preferenceKey),
           let menuBar = saved["menuBar"] as? Bool, let dock = saved["dock"] as? Bool,
           menuBar || dock {
            configuration = AppAccessConfiguration(menuBar: menuBar, dock: dock)
        } else {
            configuration = AppAccessConfiguration()
            if defaults?.object(forKey: Self.preferenceKey) != nil { persist() }
        }
    }
    @discardableResult func setMenuBar(_ enabled: Bool) -> Bool {
        update(AppAccessConfiguration(menuBar: enabled, dock: configuration.dock))
    }
    @discardableResult func setDock(_ enabled: Bool) -> Bool {
        update(AppAccessConfiguration(menuBar: configuration.menuBar, dock: enabled))
    }
    @discardableResult private func update(_ value: AppAccessConfiguration) -> Bool {
        guard value.isValid else { message = "Keep at least one way to open Codex Inbox enabled."; return false }
        guard value != configuration else { return true }
        message = ""; configuration = value; persist(); return true
    }
    func recoverRemovedStatusItem() {
        _ = update(AppAccessConfiguration(menuBar: false, dock: true))
        message = "The menu bar item was removed. Codex Inbox is available in the Dock."
    }
    private func persist() {
        defaults?.set(["menuBar": configuration.menuBar, "dock": configuration.dock], forKey: Self.preferenceKey)
    }
}

enum InboxWindowPlacement {
    /// Keep a reachable title bar where it is; recover only a stranded/oversized window.
    static func recover(_ frame: NSRect, screens: [NSRect]) -> NSRect {
        guard let first = screens.first else { return frame }
        let titlePoint = NSPoint(x: frame.midX, y: frame.maxY - 14)
        if screens.contains(where: { $0.contains(titlePoint) && frame.width <= $0.width && frame.height <= $0.height }) { return frame }
        let screen = screens.min { left, right in
            hypot(left.midX - frame.midX, left.midY - frame.midY) < hypot(right.midX - frame.midX, right.midY - frame.midY)
        } ?? first
        let size = NSSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
        return NSRect(x: min(max(frame.minX, screen.minX), screen.maxX - size.width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - size.height), width: size.width, height: size.height)
    }
}
