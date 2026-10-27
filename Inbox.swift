import AppKit
import SwiftUI
import UserNotifications

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var inbox: Inbox!
    var access: AppAccess!
    var presentation: InboxPresentation!
    var ownership: AppInstanceOwner?
    private var openRequested = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--render"), args.count > index + 1 {
            render(to: args[index + 1], dark: args.contains("--dark")); return
        }
        let background = args.contains("--background")
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Codex Inbox")
        do {
            let claim = try AppInstanceOwner.claim(directory: dir, explicitOpen: !background) { [weak self] in
                Task { @MainActor in self?.openRequested = true; self?.presentation?.showInbox() }
            }
            guard case .owner(let owner) = claim else { NSApp.terminate(nil); return }
            ownership = owner
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            if !background {
                let alert = NSAlert(); alert.messageText = "Codex Inbox could not open"
                alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "OK"); alert.runModal()
            }
            NSApp.terminate(nil); return
        }
        // No store, preferences, permission request, timer or collector exists before ownership.
        access = AppAccess(); inbox = Inbox()
        presentation = InboxPresentation(inbox: inbox, access: access)
        inbox.changed = { [weak self] in self?.presentation.updateBadge() }
        UNUserNotificationCenter.current().delegate = self
        if !background || openRequested { presentation.showInbox() }
        inbox.start()
    }
    @objc func showInbox() { presentation?.showInbox() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openRequested = true; showInbox(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        presentation?.shutdown(); inbox?.stop(); ownership?.close(); ownership = nil
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .list]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["noticeID"] as? String
        Task { @MainActor in
            if let id { self.inbox.openNotice(id: id) }
            else { self.showInbox() }
        }
        completionHandler()
    }
    func render(to path: String, dark: Bool) {
        let sample = Inbox(demo: true)
        if let index = CommandLine.arguments.firstIndex(of: "--section"), CommandLine.arguments.count > index + 1,
           let section = InboxSection.allCases.first(where: { $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "-") == CommandLine.arguments[index + 1] }) { sample.setSection(section) }
        if CommandLine.arguments.contains("--projects") { sample.selectProject("local\u{1f}inbox") }
        if CommandLine.arguments.contains("--notifications") { sample.query.showNotifications = true }
        if CommandLine.arguments.contains("--selected") { sample.selectAllNotices() }
        if CommandLine.arguments.contains("--empty") { sample.query.search = "No matching fixture" }
        if CommandLine.arguments.contains("--disconnected") { sample.disconnectDemo() }
        if CommandLine.arguments.contains("--history") { sample.setSection(.history) }
        if CommandLine.arguments.contains("--done") { sample.setSection(.done) }
        if CommandLine.arguments.contains("--open-error") { sample.opener.error = TaskOpenFailure.applicationExited.message + " The notification has not been marked done." }
        let args = CommandLine.arguments, card = args.contains("--card"), settings = args.contains("--access-settings")
        if let index = args.firstIndex(of: "--card-state"), args.count > index + 1 { try? sample.prepareCardDemo(args[index + 1]) }
        let content: AnyView
        if card { content = AnyView(InboxCard(inbox: sample, openInbox: {}, review: { _ in }, settings: {}, dismiss: {}, opaquePreview: args.contains("--reduce-transparency"))) }
        else if settings {
            let access = AppAccess(defaults: nil)
            if args.contains("--both") || args.contains("--dock-only") { access.setDock(true) }
            if args.contains("--dock-only") { access.setMenuBar(false) }
            content = AnyView(InboxAccessSettings(access: access, inbox: sample, openInbox: {}, quit: {}))
        } else if let index = args.firstIndex(of: "--messages-thread"), args.count > index + 1 {
            do {
                let sizeIndex = args.firstIndex(of: "--messages-size")
                let size = sizeIndex.flatMap { args.count > $0 + 1 ? Int(args[$0 + 1]) : nil } ?? 12
                var request = ["--thread", args[index + 1], "--messages-page", "--with-routing", "--page-size", String(size)]
                if let before = args.firstIndex(of: "--messages-before"), args.count > before + 1 { request += ["--before", args[before + 1]] }
                let page = try JSONDecoder().decode(SavedTranscriptPage.self, from: ConversationMapReader.run(request))
                let projectIndex = args.firstIndex(of: "--messages-project")
                let project = projectIndex.flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
                content = AnyView(SavedMessagesView(inbox: sample, showMap: { _ in }, showAlerts: {}, preview: page, previewProject: project))
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); NSApp.terminate(nil); return
            }
        } else if let index = args.firstIndex(of: "--map-thread"), args.count > index + 1 {
            // Explicit offscreen verification reads saved Codex history only.
            // It never owns the live Inbox store or starts the collector.
            do {
                let hoursIndex = args.firstIndex(of: "--map-hours")
                let hours = hoursIndex.flatMap { args.count > $0 + 1 ? Double(args[$0 + 1]) : nil } ?? 2
                let snapshot = try ConversationMapReader.load(thread: args[index + 1], hours: hours)
                let task = TaskIdentity(thread: snapshot.root.id, title: snapshot.root.name)
                content = AnyView(ConversationMapView(inbox: sample, requested: .constant(task), preview: snapshot, tracePreview: args.contains("--map-trace")))
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                NSApp.terminate(nil); return
            }
        } else { content = AnyView(InboxView(inbox: sample, layout: args.contains("--timeline") ? .timeline : .byChat)) }
        let view = NSHostingView(rootView: content)
        view.appearance = NSAppearance(named: args.contains("--high-contrast") ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : (dark ? .darkAqua : .aqua))
        view.frame = NSRect(x: 0, y: 0, width: card ? 360 : settings ? 430 : args.contains("--compact") ? (args.contains("--messages-thread") ? 500 : 700) : args.contains("--wide") ? 1280 : 960, height: card ? 490 : settings ? 490 : args.contains("--short") ? 460 : args.contains("--tall") ? (args.contains("--messages-thread") ? 2600 : 1800) : 730)
        let testWindow = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        testWindow.contentView = view
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }
}

@main struct Program {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
