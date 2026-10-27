import AppKit
import SwiftUI

struct InboxCard: View {
    @ObservedObject var inbox: Inbox
    var openInbox: () -> Void
    var review: (StoredNotice) -> Void
    var settings: () -> Void
    var dismiss: () -> Void
    var opaquePreview = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var problem: String {
        [inbox.storageError, inbox.sourceError, inbox.warning, inbox.notificationPermission].first { !$0.isEmpty } ?? ""
    }
    private var stale: Bool {
        guard let at = inbox.lastCollectorContactAt else { return true }
        return inbox.clock.stamp().at - at > 90
    }
    private var status: String {
        if !inbox.ready { return "Opening local history…" }
        if !inbox.connected { return inbox.history ? "Local history · reconnecting" : "Waiting for the collector" }
        if !inbox.history { return "Syncing saved history quietly…" }
        return stale ? "Connection needs confirmation" : "Listening for updates"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "tray.full.fill").font(.title2).foregroundStyle(Color.inboxAccent)
                Text("Codex Inbox").font(.headline)
                Spacer(minLength: 0)
                Button { inbox.sound.toggle() } label: {
                    Image(systemName: inbox.sound ? "speaker.wave.2" : "speaker.slash")
                }.buttonStyle(.borderless).help(inbox.sound ? "Mute sounds" : "Unmute sounds")
                    .accessibilityLabel(inbox.sound ? "Mute sounds" : "Unmute sounds")
                Button(action: settings) { Label("Settings", systemImage: "gearshape").font(.caption) }
                    .buttonStyle(.borderless).help("Settings").accessibilityLabel("Codex Inbox settings")
            }
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(inbox.ready ? String(inbox.pendingCount) : "—").font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("need attention").font(.body).foregroundStyle(Color.inboxSecondary)
            }.frame(height: 42, alignment: .leading).accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 4) {
                Text(inbox.ready ? "\(inbox.snapshot.working) working · \(inbox.snapshot.waiting) waiting" : "Reading saved activity…").font(.callout).monospacedDigit()
                Text(inbox.snapshot.unconfirmed > 0 ? "\(inbox.snapshot.unconfirmed) unconfirmed" : "Local + observed cloud tasks")
                    .font(.caption).foregroundStyle(inbox.snapshot.unconfirmed > 0 ? Color.primary : Color.inboxSecondary)
            }.frame(height: 34, alignment: .topLeading)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Label(status, systemImage: inbox.connected && !stale ? "circle.fill" : "circle.dotted")
                    .font(.caption).foregroundStyle(inbox.connected && !stale ? Color.inboxAccent : Color.inboxSecondary)
                Text(inbox.lastCollectorContactAt.map { "Collector checked " + DisplayTime.ago($0, now: inbox.clock.stamp().at) } ?? "No collector check yet")
                    .font(.caption).foregroundStyle(Color.inboxSecondary)
                Text(problem.isEmpty ? "Full history stays on this Mac." : problem)
                    .font(.caption).foregroundStyle(problem.isEmpty ? Color.inboxSecondary : Color.primary).lineLimit(2)
            }.frame(height: 65, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent notifications").font(.caption).foregroundStyle(Color.inboxSecondary)
                VStack(spacing: 4) {
                    if inbox.snapshot.recentActionable.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(inbox.ready ? "Nothing needs attention" : "Loading your inbox…").font(.body)
                            Text(inbox.ready ? "New requests and outcomes will appear here." : "You can open the main window while history loads.")
                                .font(.caption).foregroundStyle(Color.inboxSecondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    } else {
                        ForEach(inbox.snapshot.recentActionable.prefix(3)) { row in
                            Button { review(row) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: row.notice.symbol).foregroundStyle(row.notice.tint).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.task.displayTitle).font(.callout).fontWeight(.medium).lineLimit(2)
                                        Text(row.notice.label + " · " + (row.seen ? "Seen" : "Unseen")).font(.caption).foregroundStyle(Color.inboxSecondary).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Color.inboxSecondary)
                                }.frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Review in Codex Inbox")
                                .accessibilityLabel("Review " + row.task.displayTitle + ", " + row.notice.label + (row.seen ? ", seen" : ", unseen"))
                        }
                        Spacer(minLength: 0)
                    }
                }.frame(height: 152)
            }
            Divider()
            Button("Open Codex Inbox", action: openInbox).keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                .accessibilityHint("Show the existing main window")
        }
        .padding(16).frame(width: 360, height: 490)
        .background { if reduceTransparency || opaquePreview || contrast == .increased { Color(nsColor: .windowBackgroundColor) } else { Rectangle().fill(.regularMaterial) } }
        .onExitCommand(perform: dismiss)
    }
}

struct InboxAccessSettings: View {
    @ObservedObject var access: AppAccess
    @ObservedObject var inbox: Inbox
    var openInbox: () -> Void
    var quit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Notification sounds").font(.headline)
            Toggle("Mute sounds", isOn: Binding(get: { !inbox.sound }, set: { inbox.sound = !$0 }))
            HStack {
                Picker("Sound", selection: $inbox.alertSound) {
                    ForEach(InboxAlertSound.allCases) { sound in Text(sound.rawValue).tag(sound) }
                }
                Button("Preview") { inbox.previewSound() }.disabled(!inbox.sound)
            }
            Text("Mute silences sounds; banners and collection continue. Missed history and initial request snapshots load quietly.")
                .font(.callout).foregroundStyle(Color.inboxSecondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("App access").font(.headline)
            Toggle("Show in menu bar", isOn: Binding(get: { access.configuration.menuBar }, set: { _ = access.setMenuBar($0) }))
                .disabled(!access.configuration.dock)
            Toggle("Show in Dock", isOn: Binding(get: { access.configuration.dock }, set: { _ = access.setDock($0) }))
                .disabled(!access.configuration.menuBar)
            Text("Keep at least one way to open Codex Inbox enabled. Changes apply immediately.")
                .font(.callout).foregroundStyle(Color.inboxSecondary).fixedSize(horizontal: false, vertical: true)
            Text(access.message.isEmpty ? "Closing a window keeps monitoring running. App access does not change startup or collection settings." : access.message)
                .font(.caption).foregroundStyle(Color.inboxSecondary).frame(height: 40, alignment: .topLeading)
            Divider()
            HStack {
                Button("Open Codex Inbox", action: openInbox)
                Spacer()
                Button("Quit", action: quit)
            }
        }.padding(22).frame(width: 430, height: 490)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
