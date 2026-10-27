import AppKit
import SwiftUI

struct InboxView: View {
    @ObservedObject var inbox: Inbox
    @ObservedObject var opener: TaskOpener
    @ObservedObject var clockCheck: ClockCheck
    @State private var noticeLayout: NoticeListLayout
    @State private var mapTask: TaskIdentity?
    private let mapPreview: ConversationMapSnapshot?
    private let transcriptPreview: SavedTranscriptPage?
    init(inbox: Inbox, layout: NoticeListLayout = .messages, mapPreview: ConversationMapSnapshot? = nil, transcriptPreview: SavedTranscriptPage? = nil) {
        self.inbox = inbox; opener = inbox.opener; clockCheck = inbox.clockCheck
        _noticeLayout = State(initialValue: layout)
        self.mapPreview = mapPreview
        self.transcriptPreview = transcriptPreview
        _mapTask = State(initialValue: mapPreview.map { TaskIdentity(thread: $0.root.id, title: $0.root.name) })
    }
    private var showsMap: Bool { noticeLayout == .map && !inbox.query.isTaskView && inbox.query.section != .history }
    private var showsMessages: Bool { noticeLayout == .messages && !inbox.query.isTaskView && inbox.query.section != .history }
    private var warning: String {
        [inbox.storageError, opener.error, inbox.sourceError, clockCheck.warning, inbox.warning, inbox.notificationPermission].first { !$0.isEmpty } ?? ""
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Divider()
            GeometryReader { geometry in
              VStack(spacing: 0) {
                toolbar
                CurrentlyRunningSection(inbox: inbox, availableSize: geometry.size)
                Divider()
                if !warning.isEmpty { warningBar }
                filters
                Divider()
                if !inbox.query.isTaskView && inbox.query.section != .history && !showsMap && !showsMessages { selectionBar; Divider() }
                content
                if !inbox.actionMessage.isEmpty {
                    Divider()
                    HStack {
                        Text(inbox.actionMessage).foregroundStyle(Color.inboxSecondary)
                        Spacer()
                        if inbox.lastUndo != nil { Button("Undo") { inbox.undoLastAction() }.keyboardShortcut("z", modifiers: .command) }
                        Button { inbox.actionMessage = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss action summary")
                    }.font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 9)
                }
                footer
              }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, idealWidth: 960, minHeight: 460, idealHeight: 730)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $inbox.detailNotice) { NoticeDetails(inbox: inbox, item: $0) }
        .onChange(of: inbox.query.project) { mapTask = nil }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full.fill").font(.system(size: 22)).foregroundStyle(Color.inboxAccent)
                Text("Codex Inbox").font(.system(size: 16, weight: .semibold))
            }.padding(.horizontal, 16).padding(.top, 20)
            VStack(alignment: .leading, spacing: 4) {
                Label(inbox.connected ? "Listening" : inbox.history ? "Local history" : "Reconnecting…", systemImage: inbox.connected ? "circle.fill" : "circle.dotted")
                    .foregroundStyle(inbox.connected ? Color.inboxAccent : .orange)
                Text("\(inbox.snapshot.working) working · \(inbox.snapshot.waiting) waiting").foregroundStyle(Color.inboxSecondary)
                if inbox.snapshot.unconfirmed > 0 { Text("\(inbox.snapshot.unconfirmed) unconfirmed").foregroundStyle(Color.inboxSecondary) }
            }.font(.system(size: 11)).padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    sectionLabel("NOTIFICATIONS")
                    ForEach(InboxSection.notifications, id: \.self) { navigation($0) }
                    sectionLabel("CHATS & AGENTS")
                    ForEach(InboxSection.taskViews, id: \.self) { navigation($0) }
                    Divider().padding(.vertical, 7)
                    navigation(.history)
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }
    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundStyle(Color.inboxSecondary)
            .padding(.horizontal, 9).padding(.top, 13).padding(.bottom, 5)
    }
    private func navigation(_ section: InboxSection) -> some View {
        let selected = inbox.query.section == section
        return Button { inbox.setSection(section) } label: {
            HStack(spacing: 8) {
                Image(systemName: section.symbol).frame(width: 17).foregroundStyle(selected ? .inboxAccent : Color.inboxSecondary)
                Text(section.rawValue).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                Spacer(minLength: 0)
                if let count = inbox.snapshot.sectionCounts[section], count > 0 {
                    Text(count > 9999 ? "9k+" : String(count)).font(.system(size: 10)).monospacedDigit().foregroundStyle(Color.inboxSecondary)
                }
            }.font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.inboxAccent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var toolbar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(showsMap ? "Conversation map" : inbox.query.section.rawValue).font(.system(size: 21, weight: .semibold))
                Text(showsMap ? "Saved turns, messages and recorded handoffs from local history." : showsMessages ? "Saved parent and subagent messages together, oldest to newest inside each chat." : subtitle).font(.system(size: 12)).foregroundStyle(Color.inboxSecondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            Button { inbox.sound.toggle() } label: {
                Image(systemName: inbox.sound ? "speaker.wave.2" : "speaker.slash")
            }.buttonStyle(.plain).help(inbox.sound ? "Mute sounds" : "Unmute sounds")
                .accessibilityLabel(inbox.sound ? "Mute sounds" : "Unmute sounds")
            Menu {
                Button("Settings…") { inbox.showAccessSettings?() }
                Divider()
                Toggle("Mute sounds", isOn: Binding(get: { !inbox.sound }, set: { inbox.sound = !$0 }))
                Button("Test alert") { inbox.test() }
                Divider()
                Text(clockCheck.status)
                Button("Check clock now") { Task { await clockCheck.check(force: true) } }
                Divider()
                Button("Quit Codex Inbox") { NSApplication.shared.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
                .menuStyle(.borderlessButton).frame(width: 25).help("Inbox settings")
        }.padding(.horizontal, 18).padding(.vertical, 17)
    }
    private var subtitle: String {
        if !inbox.ready { return "Opening local history…" }
        if inbox.connected && !inbox.history { return "Syncing saved history quietly…" }
        switch inbox.query.section {
        case .attention: return "Review turn results and requests, grouped by project and chat."
        case .questions: return "Direct and asynchronous questions from your tasks."
        case .approvals: return "Requests for your permission."
        case .input: return "Connected tools waiting for your input."
        case .finished: return "Finished work, ready for you to review."
        case .interrupted: return "Interrupted turns. The reason may not have been supplied."
        case .failed: return "Failed work and older problems with unknown outcomes."
        case .running: return "Confirmed working and waiting tasks, grouped with their parents."
        case .unconfirmed: return "Previously active tasks awaiting fresh status. Not counted as running."
        case .recent: return "Opening requests made from Inbox, including failed attempts."
        case .dot: return "Dot and tasks linked by recorded creation relationships."
        case .subagents: return "Subagents grouped under their parent chats."
        case .done: return "Handled notifications. Reopen any that need another look."
        case .all: return "Every notification, with seen and attention states kept separate."
        case .history: return "The permanent record of notifications, actions and observations."
        }
    }
    private var warningBar: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle").foregroundStyle(.orange)
            Text(warning).frame(maxWidth: .infinity, alignment: .leading)
            if warning == opener.error {
                Button { opener.error = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss opening error")
            }
        }.font(.system(size: 11)).padding(11).background(.orange.opacity(0.07))
    }
    private var filters: some View {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                if showsMap {
                    Label("Saved history · Read-only", systemImage: "clock.arrow.circlepath").font(.system(size: 11)).foregroundStyle(Color.inboxSecondary)
                    Spacer()
                } else {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.inboxSecondary)
                    TextField(showsMessages ? "Find matching alerts or chats" : "Search chats and updates", text: Binding(get: { inbox.query.search }, set: { inbox.query.search = $0; inbox.query.limit = 100 }))
                        .textFieldStyle(.plain).font(.system(size: 12))
                    if !inbox.query.search.isEmpty { Button { inbox.query.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Color.inboxSecondary) }
                }
                Menu {
                    Button("All projects") { inbox.selectProject(nil) }
                    ForEach(inbox.snapshot.projects) { project in Button(project.name) { inbox.selectProject(project.id) } }
                } label: {
                    Label(inbox.query.project.flatMap { key in inbox.snapshot.projects.first { $0.id == key }?.name } ?? "All projects", systemImage: "folder")
                        .lineLimit(1).frame(maxWidth: 140)
                }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            }
            if (inbox.query.section == .dot || inbox.query.section == .subagents) && inbox.query.showNotifications {
                HStack { sourceToggle; Spacer(minLength: 0) }
            }
            HStack(spacing: 9) {
                if (inbox.query.section == .dot || inbox.query.section == .subagents) && !inbox.query.showNotifications {
                    sourceToggle
                }
                if !inbox.query.isTaskView && inbox.query.section != .history && !showsMap {
                    if ![.attention, .done, .all].contains(inbox.query.section) {
                        Picker("Attention", selection: $inbox.query.attention) {
                            ForEach(AttentionFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(maxWidth: 155)
                    }
                    Picker("Seen state", selection: $inbox.query.seen) {
                        ForEach(SeenFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(maxWidth: 137)
                }
                Spacer(minLength: 0)
                if !inbox.query.isTaskView && inbox.query.section != .history {
                    Picker("View", selection: $noticeLayout) {
                        ForEach(NoticeListLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 270)
                        .help("Messages interleaves saved conversations; Alerts keeps notification actions; Updates orders alerts; Map traces recorded handoffs.")
                }
                if !showsMap {
                    Text("\(inbox.snapshot.matchingCount) " + (showsMessages ? "matching alert" : inbox.query.isTaskView ? "conversation" : inbox.query.section == .history ? "event" : "update") + (inbox.snapshot.matchingCount == 1 ? "" : "s"))
                        .font(.system(size: 11)).foregroundStyle(Color.inboxSecondary).monospacedDigit().fixedSize()
                }
            }.controlSize(.small)
            if inbox.query.task != nil {
                HStack {
                    Label(inbox.historyTaskTitle ?? "Selected task", systemImage: "bubble.left").lineLimit(1)
                    Spacer()
                    Button("Clear task filter") { inbox.query.task = nil; inbox.historyTaskTitle = nil }
                }.font(.system(size: 11))
            }
        }.padding(.horizontal, 18).padding(.bottom, 13)
    }
    private var sourceToggle: some View {
        Picker("Content", selection: $inbox.query.showNotifications) {
            Text("Tasks").tag(false); Text("Notifications").tag(true)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 175).controlSize(.small)
    }
    private var selectionBar: some View {
        let count = inbox.selectedIDs.count
        let all = count > 0 && Set(inbox.snapshot.matchingIDs).isSubset(of: inbox.selectedIDs)
        return HStack(spacing: 10) {
            Button { if all { inbox.selectedIDs = [] } else { inbox.selectAllNotices() } } label: {
                Image(systemName: all ? "checkmark.square.fill" : count > 0 ? "minus.square.fill" : "square").font(.system(size: 15))
            }.buttonStyle(.plain).disabled(inbox.snapshot.matchingCount == 0).help("Select every matching notification, including earlier pages")
                .accessibilityLabel(all ? "Clear notification selection" : "Select all matching notifications")
            Text(count == 0 ? "Select notifications" : "\(count) selected").font(.system(size: 11)).foregroundStyle(Color.inboxSecondary).monospacedDigit()
            Spacer(minLength: 4)
            if count > 0 {
                Button("Mark seen") { inbox.perform(.seen) }
                Button("Done") { inbox.perform(.done) }
                Menu {
                    Button("Mark unseen") { inbox.perform(.unseen) }
                    Button("Reopen") { inbox.perform(.reopen) }
                    Divider()
                    Button("Copy task links") { inbox.copySelection(links: true) }
                    Button("Copy text") { inbox.copySelection(links: false) }
                    Divider()
                    Button("Clear selection") { inbox.selectedIDs = [] }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
            } else { Text("⌘ click · ⇧ range").font(.system(size: 10)).foregroundStyle(Color.inboxSecondary).accessibilityHidden(true) }
        }.controlSize(.small).disabled(inbox.batchBusy).padding(.horizontal, 16).frame(height: 40)
            .background(count > 0 ? Color.inboxAccent.opacity(0.055) : .clear)
    }
    @ViewBuilder private var content: some View {
        if showsMap {
            ConversationMapView(inbox: inbox, requested: $mapTask, preview: mapPreview)
        } else if showsMessages && (inbox.snapshot.matchingCount > 0 || transcriptPreview != nil) {
            SavedMessagesView(inbox: inbox, showMap: { task in mapTask = task; noticeLayout = .map }, showAlerts: { noticeLayout = .byChat }, preview: transcriptPreview)
        } else if inbox.snapshot.matchingCount == 0 {
            VStack(spacing: 12) {
                Image(systemName: inbox.query.section.symbol).font(.system(size: 32, weight: .light)).foregroundStyle(Color.inboxSecondary)
                Text(inbox.ready ? (inbox.query.search.isEmpty ? "Nothing here right now" : "No matching results") : "Opening your inbox…").font(.system(size: 17, weight: .medium))
                Text(inbox.query.isTaskView ? "Only tasks revealed by local records or the live connection can appear." : "Try another view or filter. Your history stays on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(Color.inboxSecondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if inbox.query.section == .history {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(inbox.snapshot.activities) { item in ActivityRow(item: item, open: { inbox.open(item) }, history: { inbox.showHistory(item.task) }) }
                    if inbox.snapshot.activities.count < inbox.snapshot.matchingCount { loadMore }
                }.padding(18)
            }
        } else if inbox.query.isTaskView {
            TaskCollection(inbox: inbox)
        } else {
            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    NativeNoticeList(inbox: inbox, layout: noticeLayout, showMap: { task in mapTask = task; noticeLayout = .map })
                }
                if inbox.snapshot.notices.count < inbox.snapshot.matchingCount { loadMore.padding(.vertical, 8) }
            }
        }
    }
    private var loadMore: some View { Button("Load earlier entries") { inbox.query.limit += 100 }.buttonStyle(.plain).foregroundStyle(Color.inboxAccent).font(.system(size: 12)) }
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 5) {
                Image(systemName: "externaldrive")
                Text(inbox.query.isTaskView ? "Local + observed cloud tasks" : "History kept on this Mac")
                    .help("No automatic deletion. Cloud tasks that have never been revealed to the local app may be missing.")
                Spacer(minLength: 4)
                Image(systemName: "clock").help(clockCheck.status)
                Text("No AI usage")
            }.font(.system(size: 10)).foregroundStyle(Color.inboxSecondary).padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
}

struct CurrentlyRunningSection: View {
    @ObservedObject var inbox: Inbox
    let availableSize: CGSize
    @State private var collapsed = false

    private var projects: [RunningProject] { inbox.snapshot.runningProjects }
    private var count: Int { inbox.snapshot.working + inbox.snapshot.waiting }
    private var runningSummary: String {
        let agents = projects.flatMap(\.tasks).filter(\.isSubagent).count
        let chats = count - agents
        var parts: [String] = []
        if chats > 0 { parts.append("\(chats) " + (chats == 1 ? "chat" : "chats")) }
        if agents > 0 { parts.append("\(agents) " + (agents == 1 ? "subagent" : "subagents")) }
        return parts.joined(separator: " · ")
    }
    private var cardHeight: CGFloat { availableSize.height < 600 ? 106 : 154 }
    private var columnCount: Int { max(1, Int((availableSize.width - 36 + 10) / (260 + 10))) }
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: columnCount) }
    private var gridHeight: CGFloat {
        let rows = (projects.count + columnCount - 1) / columnCount
        let required = CGFloat(rows) * cardHeight + CGFloat(max(0, rows - 1)) * 10
        // Keep the notification controls and list reachable in short windows.
        return min(required, max(cardHeight, availableSize.height - 360))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { collapsed.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold))
                        Text("Currently running").font(.system(size: 12, weight: .semibold))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(collapsed ? "Show running project cards" : "Hide running project cards")
                    .accessibilityLabel(collapsed ? "Expand Currently running" : "Collapse Currently running")
                if count > 0 {
                    Text(runningSummary)
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.inboxSecondary)
                } else {
                    Text(inbox.ready ? "No confirmed running chats or subagents" : "Loading…")
                        .font(.system(size: 11)).foregroundStyle(Color.inboxSecondary)
                }
                Spacer(minLength: 0)
            }
            if !collapsed && !projects.isEmpty {
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(projects) { project in
                            RunningProjectCard(inbox: inbox, project: project, height: cardHeight)
                        }
                    }
                }.frame(height: gridHeight)
            }
        }.padding(.horizontal, 18).padding(.bottom, 13)
    }
}

struct RunningProjectCard: View {
    @ObservedObject var inbox: Inbox
    let project: RunningProject
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: project.id.isEmpty ? "bubble.left.and.bubble.right" : "folder")
                    .foregroundStyle(Color.inboxAccent)
                Text(project.name).fontWeight(.semibold).lineLimit(1).help(project.name)
                Spacer(minLength: 3)
                Text("\(project.tasks.count)").monospacedDigit().foregroundStyle(Color.inboxSecondary)
            }.font(.system(size: 12))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(project.tasks) { row in
                        RunningChatRow(inbox: inbox, row: row)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).frame(height: height, alignment: .topLeading)
            .background(Color.inboxAccent.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.inboxSecondary.opacity(0.2), lineWidth: 1))
    }
}

struct RunningChatRow: View {
    @ObservedObject var inbox: Inbox
    let row: StoredTask
    private var statusColor: Color { row.runtime?.status == "working" ? .inboxAccent : .orange }

    var body: some View {
        Button { inbox.open(row.task) } label: {
            HStack(alignment: .top, spacing: 7) {
                Circle().fill(statusColor).frame(width: 5, height: 5).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.task.displayTitle).font(.system(size: 12, weight: .medium))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Text((row.isSubagent ? "Subagent · " : "Chat · ") + row.status).font(.system(size: 10)).foregroundStyle(Color.inboxSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Color.inboxSecondary).padding(.top, 3)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .disabled(inbox.isOpening(TaskLaunch(thread: row.task.thread, host: row.task.host)?.url))
            .help("Open " + row.task.displayTitle + " · " + row.status)
            .accessibilityLabel("Open " + row.task.displayTitle + ", " + row.status)
    }
}

struct TaskCollection: View {
    @ObservedObject var inbox: Inbox
    @State private var collapsed: Set<String> = []
    private var flattened: [(StoredTask, Int, Bool)] {
        let rows = inbox.snapshot.taskRows
        if inbox.query.section == .recent { return rows.map { ($0, 0, false) } }
        let ids = Set(rows.map(\.id))
        let children = Dictionary(grouping: rows.filter { $0.parentKey != $0.id && $0.parentKey.map(ids.contains) == true }, by: { $0.parentKey! })
        var result: [(StoredTask, Int, Bool)] = [], visited = Set<String>()
        func walk(_ row: StoredTask, _ depth: Int) {
            guard visited.insert(row.id).inserted else { return }
            let nested = children[row.id] ?? []
            result.append((row, min(depth, 5), !nested.isEmpty))
            if collapsed.contains(row.id) {
                func hide(_ row: StoredTask) { guard visited.insert(row.id).inserted else { return }; for child in children[row.id] ?? [] { hide(child) } }
                for child in nested { hide(child) }
            } else { for child in nested { walk(child, depth + 1) } }
        }
        for row in rows where row.parentKey == nil || !ids.contains(row.parentKey!) { walk(row, 0) }
        for row in rows where !visited.contains(row.id) { walk(row, 0) }
        return result
    }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(flattened, id: \.0.id) { row, depth, hasChildren in
                    HStack(alignment: .top, spacing: 5) {
                        if hasChildren {
                            Button { if !collapsed.insert(row.id).inserted { collapsed.remove(row.id) } } label: {
                                Image(systemName: collapsed.contains(row.id) ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 15, height: 22)
                            }.buttonStyle(.plain).help("Show or hide child tasks")
                        } else { Color.clear.frame(width: 15, height: 1) }
                        TaskCard(inbox: inbox, row: row)
                    }.padding(.leading, CGFloat(depth) * 15).padding(.vertical, 13)
                    Divider()
                }
                if inbox.snapshot.taskRows.filter({ !$0.contextOnly }).count < inbox.snapshot.matchingCount {
                    Button("Load more tasks") { inbox.query.limit += 100 }.buttonStyle(.plain).foregroundStyle(Color.inboxAccent).padding(14)
                }
            }.padding(.horizontal, 14)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }
}

struct TaskCard: View {
    @ObservedObject var inbox: Inbox
    let row: StoredTask
    @State private var showLinks = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.task.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(2).help(row.task.displayTitle)
                    HStack(spacing: 7) {
                        Text(row.contextOnly ? "Parent task · " + row.status : row.status)
                            .foregroundStyle(row.isUnconfirmed ? Color.orange : .inboxSecondary)
                        if let origin = row.originLabel { Text(origin).foregroundStyle(Color.inboxAccent) }
                        if let project = row.task.projectName { Text(project).foregroundStyle(Color.inboxSecondary).lineLimit(1) }
                    }.font(.system(size: 11))
                }
                Spacer(minLength: 4)
                Button("Open") { inbox.open(row.task) }.controlSize(.small).disabled(inbox.isOpening(TaskLaunch(thread: row.task.thread, host: row.task.host)?.url))
            }
            if inbox.query.section == .recent, let clicked = row.lastClickedAt {
                Text((row.openResult == "accepted" ? "Opened from Inbox " : "Opening requested ") + DisplayTime.ago(clicked, now: inbox.clock.stamp().at) + (row.openResult == "failed" ? " · failed" : row.openResult == "accepted" ? "" : " · outcome unavailable"))
                    .font(.system(size: 11)).foregroundStyle(row.openResult == "failed" ? Color.orange : .inboxSecondary)
                    .help((row.openDetail ?? "") + " OS acceptance does not verify task display.")
            }
            if let key = row.parentKey, let parent = inbox.snapshot.taskCatalog[key] {
                Button((row.parentKind == "subagent" ? "Subagent of " : "Created by ") + parent.task.displayTitle) { inbox.open(parent.task) }
                    .buttonStyle(.plain).foregroundStyle(Color.inboxAccent).font(.system(size: 11)).lineLimit(1)
            }
            HStack(spacing: 13) {
                Button(row.pending > 0 ? "\(row.pending) " + (row.pending == 1 ? "needs" : "need") + " attention" : "Notifications") { inbox.showNotifications(row.task) }
                Button("History") { inbox.showHistory(row.task) }
                if !row.relations.isEmpty { Button("Relationships") { showLinks.toggle() } }
                Spacer(minLength: 0)
                if let observed = row.observedAt, inbox.query.section != .recent {
                    Text("Observed " + DisplayTime.ago(observed, now: inbox.clock.stamp().at)).foregroundColor(Color(nsColor: .secondaryLabelColor)).font(.system(size: 10))
                        .help("Last status observation: " + DisplayTime.full(observed) + (row.isUnconfirmed ? ". Awaiting live confirmation." : ""))
                }
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.inboxAccent)
            if showLinks {
                ForEach(Array(row.relations.enumerated()), id: \.offset) { _, relation in
                    let matches = inbox.snapshot.taskCatalog.values.filter { $0.task.thread == relation.parentThread && (relation.parentHost == nil || $0.task.host == relation.parentHost) }
                    let label = relation.kind == "created" ? "Created by" : relation.kind == "subagent" ? "Subagent of" : "Delegated by"
                    if matches.count == 1, let parent = matches.first {
                        Button(label + " " + parent.task.displayTitle) { inbox.open(parent.task) }.buttonStyle(.plain).foregroundStyle(Color.inboxAccent)
                    } else { Text(label + " " + String(relation.parentThread.prefix(8)) + " · source unavailable").foregroundStyle(Color.inboxSecondary) }
                }.font(.system(size: 11))
            }
        }
        .contextMenu {
            Button("Open in Codex") { inbox.open(row.task) }
            Button("Notifications") { inbox.showNotifications(row.task) }
            Button("Task history") { inbox.showHistory(row.task) }
            if let url = TaskLaunch(thread: row.task.thread, host: row.task.host)?.url {
                Button("Copy task link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
            }
        }
    }
}

struct NoticeDetails: View {
    @ObservedObject var inbox: Inbox
    let item: StoredNotice
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.task.displayTitle).font(.headline)
                    Text(item.notice.label + " · " + (item.seen ? "Seen" : "Unseen") + " · " + (item.needsAttention ? "Needs attention" : "Done")).font(.subheadline).foregroundStyle(Color.inboxSecondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.notice.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    if item.notice.timeSource != "unknown" { Text("Source time: " + DisplayTime.full(item.notice.created)) }
                    if let clicked = item.clickedAt { Text("Clicked to open: " + DisplayTime.full(clicked)) }
                    if let opened = item.openedAt { Text("Opening accepted by macOS: " + DisplayTime.full(opened)) }
                    if item.previouslySeen { Text("Imported Seen state. Earlier reading time may be unknown.") }
                    if let runtime = inbox.snapshot.taskCatalog[item.task.key], let detail = runtime.openDetail { Text(detail) }
                    if let origin = item.originLabel { Text("Current task classification: " + origin) }
                    if let reason = item.doneReason { Text("Handled: " + reason) }
                    if item.notice.estimated == true { Text("The panel timer is an estimate, not an answer deadline. Expiry does not mark this notification done.") }
                    Text("Seen acknowledges this notification. Opening acceptance does not prove the task finished displaying in Codex.")
                }.font(.system(size: 12)).padding(.trailing, 10)
            }
            HStack {
                Button("Task history") { inbox.showHistory(item.task); dismiss() }
                if let banner = item.banner, banner.state != "accepted" { Button("Retry banner") { inbox.retryBanner(item) } }
                Spacer()
                Button("Open in Codex") { inbox.open(item); dismiss() }.disabled(item.notice.url == nil)
                Button(item.needsAttention ? "Done" : "Reopen") { inbox.markDone(item, done: item.needsAttention); dismiss() }
            }.controlSize(.small)
        }.padding(22).frame(width: 570, height: 420)
    }
}
