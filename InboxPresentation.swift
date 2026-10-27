import AppKit
import SwiftUI
import Combine

/// One set of windows and one compact card, all borrowing the app-owned Inbox.
/// This object never starts services or constructs another Inbox.
@MainActor final class InboxPresentation: NSObject, NSPopoverDelegate {
    let inbox: Inbox
    let access: AppAccess
    let mainWindow: NSWindow
    let popover = NSPopover()
    private(set) var settingsWindow: NSWindow?
    private(set) var statusItem: NSStatusItem?
    private var observation: NSKeyValueObservation?
    private var preferences: AnyCancellable?
    private var screenObservation: NSObjectProtocol?
    private let systemUI: Bool
    private let screens: @MainActor () -> [NSRect]
    private let reveal: @MainActor (NSWindow) -> Void
    private let applyPolicy: @MainActor (Bool) -> Bool
    private var appliedDock: Bool?

    init(inbox: Inbox, access: AppAccess, systemUI: Bool = true,
         screens: @escaping @MainActor () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) },
         applyPolicy: @escaping @MainActor (Bool) -> Bool = { NSApp.setActivationPolicy($0 ? .regular : .accessory) },
         reveal: @escaping @MainActor (NSWindow) -> Void = { window in
             if window.isMiniaturized { window.deminiaturize(nil) }
             NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
         }) {
        self.inbox = inbox; self.access = access; self.systemUI = systemUI
        self.screens = screens; self.applyPolicy = applyPolicy; self.reveal = reveal
        mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 730), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        mainWindow.title = "Codex Inbox"; mainWindow.titleVisibility = .hidden
        mainWindow.titlebarAppearsTransparent = true; mainWindow.isReleasedWhenClosed = false
        mainWindow.minSize = NSSize(width: 700, height: 460); mainWindow.tabbingMode = .disallowed
        mainWindow.contentView = NSHostingView(rootView: InboxView(inbox: inbox))
        if systemUI {
            if !mainWindow.setFrameUsingName("CodexInboxWindowV2") { mainWindow.center() }
            mainWindow.setFrameAutosaveName("CodexInboxWindowV2")
        }
        recoverWindows()
        popover.behavior = .transient; popover.delegate = self
        popover.contentSize = NSSize(width: 360, height: 490)
        popover.contentViewController = NSHostingController(rootView: InboxCard(inbox: inbox,
            openInbox: { [weak self] in self?.showInbox() }, review: { [weak self] row in self?.review(row) },
            settings: { [weak self] in self?.showSettings() }, dismiss: { [weak self] in self?.closeCard() }))
        inbox.showAccessSettings = { [weak self] in self?.showSettings() }
        if systemUI { installMenus() }
        apply(access.configuration)
        preferences = access.$configuration.dropFirst().removeDuplicates().sink { [weak self] value in
            // Coalesce rapid toggles; never apply a stale setting after a newer choice.
            DispatchQueue.main.async {
                guard let self, self.access.configuration == value else { return }; self.apply(value)
            }
        }
        screenObservation = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recoverWindows() }
        }
    }
    func apply(_ value: AppAccessConfiguration) {
        if appliedDock != value.dock {
            if applyPolicy(value.dock) { appliedDock = value.dock }
            else {
                _ = access.setMenuBar(true); _ = access.setDock(appliedDock ?? false)
                access.message = "macOS could not change Dock visibility. Menu bar access remains enabled."
            }
        }
        guard systemUI else { return }
        if access.configuration.menuBar {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                statusItem = item; item.autosaveName = "CodexInboxStatusItem"; item.behavior = [.removalAllowed]
                item.isVisible = true
                item.button?.target = self; item.button?.action = #selector(statusItemClicked)
                item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                if #available(macOS 27.0, *) {
                    item.expandedInterfaceDelegate = self
                    item.button?.sendAction(on: [.rightMouseUp])
                }
                item.button?.setAccessibilityLabel("Codex Inbox summary")
                observation = item.observe(\.isVisible, options: [.new]) { [weak self] item, value in
                    guard value.newValue == false else { return }
                    Task { @MainActor [weak self, weak item] in
                        guard let self, let item, self.statusItem === item, self.access.configuration.menuBar else { return }
                        self.access.recoverRemovedStatusItem()
                    }
                }
            }
            // Also restore an existing, hidden item when Dock activation fails after removal.
            statusItem?.isVisible = true
            updateBadge()
        } else {
            closeCard(); observation = nil
            if let item = statusItem { statusItem = nil; NSStatusBar.system.removeStatusItem(item) }
        }
    }
    func updateBadge() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: inbox.pendingCount > 0 ? "tray.full.fill" : "tray", accessibilityDescription: "Codex Inbox")
        button.image?.isTemplate = true; button.imagePosition = .imageLeading
        button.title = inbox.pendingCount > 0 ? " \(inbox.pendingCount)" : ""
        button.toolTip = "Codex Inbox · \(inbox.pendingCount) need attention"
    }
    @objc func statusItemClicked() {
        guard let button = statusItem?.button else { return }
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            closeCard(); NSMenu.popUpContextMenu(secondaryMenu(), with: event, for: button)
        } else if popover.isShown { closeCard() }
        else { showCard() }
    }
    func showCard() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func closeCard() {
        popover.performClose(nil)
        if #available(macOS 27.0, *) { statusItem?.expandedInterfaceSession?.cancel() }
    }
    func popoverDidClose(_ notification: Notification) {
        if #available(macOS 27.0, *) { statusItem?.expandedInterfaceSession?.cancel() }
    }
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }
    @objc func showInbox() { closeCard(); recoverWindows(); reveal(mainWindow) }
    func review(_ row: StoredNotice) {
        // Review inside Inbox; only its explicit Open control attempts Codex navigation.
        inbox.detailNotice = row; showInbox()
    }
    @objc func showSettings() {
        closeCard()
        if settingsWindow == nil {
            let view = NSHostingView(rootView: InboxAccessSettings(access: access, inbox: inbox,
                openInbox: { [weak self] in self?.showInbox() }, quit: { NSApp.terminate(nil) }))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Codex Inbox Settings"; window.isReleasedWhenClosed = false; window.tabbingMode = .disallowed
            window.contentView = view; window.center(); settingsWindow = window
        }
        recoverWindows(); if let settingsWindow { reveal(settingsWindow) }
    }
    func recoverWindows() {
        let available = screens()
        for window in [mainWindow, settingsWindow].compactMap({ $0 }) {
            let next = InboxWindowPlacement.recover(window.frame, screens: available)
            if next != window.frame { window.setFrame(next, display: false) }
        }
    }
    private func secondaryMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Open Codex Inbox", #selector(showInbox)), ("Settings…", #selector(showSettings)), ("Quit Codex Inbox", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc private func quit() { NSApp.terminate(nil) }
    private func installMenus() {
        let menu = NSMenu(), appMenu = secondaryMenu()
        appMenu.items[0].keyEquivalent = "0"; appMenu.items[1].keyEquivalent = ","; appMenu.items[2].keyEquivalent = "q"
        let root = NSMenuItem(); root.submenu = appMenu; menu.addItem(root)
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        let editRoot = NSMenuItem(); editRoot.submenu = edit; menu.addItem(editRoot); NSApp.mainMenu = menu
    }
    func shutdown() {
        preferences = nil; observation = nil
        if let screenObservation { NotificationCenter.default.removeObserver(screenObservation) }
        screenObservation = nil; inbox.showAccessSettings = nil; closeCard()
        if let item = statusItem { statusItem = nil; NSStatusBar.system.removeStatusItem(item) }
    }
}

@available(macOS 27.0, *)
extension InboxPresentation: @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession) { showCard() }
    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) { popover.performClose(nil) }
}
