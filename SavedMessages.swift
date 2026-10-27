import AppKit
import SwiftUI

private enum TranscriptTime {
    static let formatter: DateFormatter = {
        let value = DateFormatter(); value.dateFormat = "d MMM yyyy · HH:mm:ss"; value.timeZone = .autoupdatingCurrent; return value
    }()
    static func label(_ value: Double) -> String { formatter.string(from: Date(timeIntervalSince1970: value)) }
}

struct SavedTranscriptMessage: Decodable, Identifiable, Sendable {
    var message: SavedMapMessage
    var turnNumber: Int?
    var finalForTurn: Bool
    var id: String { message.id }
}
struct SavedTranscriptPage: Decodable, Sendable {
    var root: SavedMapActor
    var actors: [SavedMapActor]
    var messages: [SavedTranscriptMessage]
    var next: String?
    var hasEarlier: Bool
    var capturedAt: Double
    var warnings: [String]
    var routing: [SavedMapHandoff]?
}
struct TranscriptFamily: Identifiable, Sendable {
    var task: TaskIdentity
    var notices: [StoredNotice]
    var id: String { task.key }
}
enum TranscriptGrouping {
    // A family has one project/chat box. Native agent ancestry determines its
    // parent; an ordinary fork/created chat remains a separate conversation.
    static func families(_ snapshot: InboxSnapshot) -> [TranscriptFamily] {
        var tasks: [String: TaskIdentity] = [:], groups: [String: [StoredNotice]] = [:], order: [String] = []
        for notice in snapshot.notices {
            var task = notice.task, visited: Set<String> = [task.key]
            while let row = snapshot.taskCatalog[task.key], row.isSubagent,
                  let key = row.parentKey, let parent = snapshot.taskCatalog[key] {
                guard visited.insert(key).inserted else { task = notice.task; break }
                task = parent.task
            }
            if groups[task.key] == nil { order.append(task.key); tasks[task.key] = task }
            groups[task.key, default: []].append(notice)
        }
        return order.compactMap { key in tasks[key].map { TranscriptFamily(task: $0, notices: groups[key] ?? []) } }
    }
}
struct TranscriptEntry: Identifiable {
    var saved: SavedTranscriptMessage?
    var alert: StoredNotice?
    var route: SavedMapHandoff?
    var notices: [StoredNotice] = []
    var id: String { saved.map { "message:" + $0.id } ?? route.map { "route:" + $0.id + ":" + $0.recipient } ?? "alert:" + alert!.id }
    var at: Double? { saved?.message.at ?? route?.at ?? (alert.flatMap { $0.notice.timeSource == "unknown" ? nil : $0.notice.created }) }
}
enum TranscriptChronology {
    static func rows(_ messages: [SavedTranscriptMessage], notices: [StoredNotice], routing: [SavedMapHandoff] = []) -> (entries: [TranscriptEntry], otherAlerts: Int) {
        var used: Set<String> = [], rows: [TranscriptEntry] = []
        for saved in messages {
            let message = saved.message
            let related = notices.filter { notice in
                guard notice.task.host == "local", notice.task.thread == message.thread, !used.contains(notice.id) else { return false }
                if notice.notice.kind == "completion" { return saved.finalForTurn && notice.notice.turn == message.turn }
                let prefix = "local:\(message.thread):question:\(message.item):"
                return notice.notice.kind == "question" && notice.id.hasPrefix(prefix) && Int(notice.id.dropFirst(prefix.count)) != nil
            }
            used.formUnion(related.map(\.id))
            rows.append(TranscriptEntry(saved: saved, notices: related))
        }
        var routeIDs: Set<String> = []
        for route in routing {
            let entry = TranscriptEntry(route: route)
            if routeIDs.insert(entry.id).inserted { rows.append(entry) }
        }
        let times = messages.compactMap { $0.message.at }
        let earliest = times.min(), latest = times.max()
        for notice in notices where !used.contains(notice.id) {
            let known = notice.notice.timeSource != "unknown"
            if messages.isEmpty || !known || (earliest != nil && notice.notice.created >= earliest! && notice.notice.created <= latest!) {
                rows.append(TranscriptEntry(alert: notice)); used.insert(notice.id)
            }
        }
        rows.sort {
            if ($0.at != nil) != ($1.at != nil) { return $0.at != nil }
            if $0.at != $1.at { return ($0.at ?? 0) < ($1.at ?? 0) }
            if let a = $0.saved?.message, let b = $1.saved?.message, a.thread == b.thread, a.ordinal != b.ordinal { return a.ordinal < b.ordinal }
            return $0.id < $1.id
        }
        return (rows, notices.filter { !used.contains($0.id) }.count)
    }
}

private final class TranscriptReadTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var active: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
}
@MainActor final class SavedTranscriptModel: ObservableObject {
    @Published var page: SavedTranscriptPage?
    @Published var messages: [SavedTranscriptMessage] = []
    @Published var routing: [SavedMapHandoff] = []
    @Published var loading = false
    @Published var error = ""
    @Published var readingEarlier = false
    private static let queue = DispatchQueue(label: "local.codex.inbox.saved-messages", qos: .userInitiated)
    private var job: DispatchWorkItem?
    private var ticket: TranscriptReadTicket?
    private var generation = 0
    private var earlierCursor: String?
    let preview: Bool
    init(preview: SavedTranscriptPage? = nil) {
        self.preview = preview != nil; page = preview; messages = preview?.messages ?? []; routing = preview?.routing ?? []; earlierCursor = preview?.next
    }
    func load(_ task: TaskIdentity, earlier: Bool = false) {
        guard !preview, !loading, earlier || !readingEarlier else { return }
        guard task.host == "local" else { error = "Saved cloud messages are unavailable locally. Your alerts are retained below."; return }
        if earlier && earlierCursor == nil { return }
        if earlier { readingEarlier = true }
        generation += 1; let request = generation, cursor = earlier ? earlierCursor : nil
        loading = true; error = ""
        let ticket = TranscriptReadTicket(); self.ticket = ticket
        let work = DispatchWorkItem { [weak self] in
            guard ticket.active else { return }
            let result = Result { () -> SavedTranscriptPage in
                var args = ["--thread", task.thread, "--messages-page", "--with-routing", "--page-size", "12"]
                if let cursor { args += ["--before", cursor] }
                return try JSONDecoder().decode(SavedTranscriptPage.self, from: ConversationMapReader.run(args))
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == request else { return }
                self.loading = false
                switch result {
                case .success(let page):
                    let existing = Dictionary(uniqueKeysWithValues: (earlier ? self.messages : []).map { ($0.id, $0) })
                    var merged = existing
                    for item in page.messages { merged[item.id] = item }
                    self.messages = Array(merged.values)
                    var routes = Dictionary(uniqueKeysWithValues: (earlier ? self.routing : []).map { ($0.id + ":" + $0.recipient, $0) })
                    for route in page.routing ?? [] { routes[route.id + ":" + route.recipient] = route }
                    self.routing = Array(routes.values)
                    self.page = page
                    self.earlierCursor = page.next
                case .failure(let failure): self.error = failure.localizedDescription
                }
            }
        }
        job = work; Self.queue.async(execute: work)
    }
    var hasEarlier: Bool { earlierCursor != nil }
    func latest(_ task: TaskIdentity) { guard !loading else { return }; readingEarlier = false; load(task) }
    func cancel() { generation += 1; ticket?.cancel(); job?.cancel(); loading = false }
}

struct SavedMessagesView: View {
    @ObservedObject var inbox: Inbox
    var showMap: (TaskIdentity) -> Void
    var showAlerts: () -> Void
    var preview: SavedTranscriptPage? = nil
    var previewProject: String? = nil
    private var families: [TranscriptFamily] {
        if let preview { return [TranscriptFamily(task: TaskIdentity(thread: preview.root.id, title: preview.root.name, projectID: previewProject, projectName: previewProject), notices: [])] }
        return TranscriptGrouping.families(inbox.snapshot)
    }
    var body: some View {
        let families = families
        let projectKeys = families.reduce(into: [String]()) { if !$0.contains($1.task.projectKey) { $0.append($1.task.projectKey) } }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                Text("Oldest → newest within each chat · Direction appears where recorded")
                    .font(.system(size: 11)).foregroundStyle(Color.inboxSecondary)
                ForEach(projectKeys, id: \.self) { key in
                    let chats = families.filter { $0.task.projectKey == key }
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Label(chats.first?.task.projectName ?? "No project", systemImage: "folder.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.inboxAccent)
                            Spacer(minLength: 0)
                            Text("\(chats.count) " + (chats.count == 1 ? "chat" : "chats")).font(.system(size: 11)).foregroundStyle(Color.inboxSecondary)
                        }.padding(.horizontal, 20).padding(.vertical, 18).background(Color.inboxAccent.opacity(0.045))
                        ForEach(chats) { family in
                            SavedFamilyMessages(inbox: inbox, family: family, showMap: showMap, showAlerts: showAlerts, preview: preview)
                        }.padding(.horizontal, 16)
                    }.padding(.bottom, 18)
                        .background(Color.inboxAccent.opacity(0.012), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.inboxAccent.opacity(0.22)))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                if preview == nil && inbox.snapshot.notices.count < inbox.snapshot.matchingCount {
                    Button("Load more matching chats and alerts") { inbox.query.limit += 100 }.controlSize(.small)
                }
            }.padding(20)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SavedFamilyMessages: View {
    @ObservedObject var inbox: Inbox
    let family: TranscriptFamily
    var showMap: (TaskIdentity) -> Void
    var showAlerts: () -> Void
    @StateObject private var model: SavedTranscriptModel
    @State private var collapsed = false
    @State private var detail: SavedTranscriptMessage?
    init(inbox: Inbox, family: TranscriptFamily, showMap: @escaping (TaskIdentity) -> Void, showAlerts: @escaping () -> Void, preview: SavedTranscriptPage? = nil) {
        self.inbox = inbox; self.family = family; self.showMap = showMap; self.showAlerts = showAlerts
        _model = StateObject(wrappedValue: SavedTranscriptModel(preview: preview))
    }
    private func actor(_ thread: String) -> SavedMapActor? { model.page?.actors.first { $0.id == thread } }
    var body: some View {
        let chronology = model.page != nil || !model.error.isEmpty ? TranscriptChronology.rows(model.messages, notices: family.notices, routing: model.routing) : (entries: [TranscriptEntry](), otherAlerts: 0)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { collapsed.toggle() } label: { Image(systemName: collapsed ? "chevron.right" : "chevron.down") }.buttonStyle(.plain).help(collapsed ? "Expand chat" : "Collapse chat")
                VStack(alignment: .leading, spacing: 4) {
                    Text("CHAT").font(.system(size: 9, weight: .bold)).foregroundStyle(.blue)
                    Text(model.page?.root.name ?? family.task.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text("\(model.messages.count) " + (model.messages.count == 1 ? "message" : "messages") + " · \(model.routing.count) recorded " + (model.routing.count == 1 ? "action" : "actions") + " · Oldest first").font(.system(size: 10)).foregroundStyle(Color.inboxSecondary)
                }
                Spacer(minLength: 0)
                Button("Map") { showMap(family.task) }.controlSize(.small)
                Button("Open chat") { inbox.open(family.task) }.controlSize(.small)
            }.padding(18).background(.blue.opacity(0.025))
            if !collapsed {
                Divider()
                if model.hasEarlier {
                    Button("Load earlier saved messages") { model.load(family.task, earlier: true) }.controlSize(.small).disabled(model.loading).padding(12)
                }
                if model.readingEarlier {
                    HStack {
                        Text("Earlier history · Live refresh paused while you read").font(.system(size: 10)).foregroundStyle(Color.inboxSecondary)
                        Spacer(minLength: 0)
                        Button("Latest messages") { model.latest(family.task) }.controlSize(.small).disabled(model.loading)
                    }.padding(12)
                }
                if model.loading || model.page == nil && model.error.isEmpty { ProgressView().controlSize(.small).padding(12) }
                if !model.error.isEmpty { Text(model.error).font(.system(size: 11)).foregroundStyle(.orange).padding(12) }
                if model.page != nil && model.messages.isEmpty && !model.loading && model.error.isEmpty { Text("No saved messages available for this chat. Its alerts remain below.").font(.system(size: 11)).foregroundStyle(Color.inboxSecondary).padding(12) }
                if let warnings = model.page?.warnings, !warnings.isEmpty { Text(warnings.joined(separator: " ")).font(.system(size: 11)).foregroundStyle(.orange).padding(12) }
                VStack(spacing: 12) {
                    ForEach(chronology.entries) { entry in
                        if let route = entry.route {
                            SavedRoutingRow(route: route, actors: model.page?.actors ?? [], root: model.page?.root.id ?? family.task.thread)
                        } else {
                            SavedTranscriptRow(inbox: inbox, entry: entry, actor: actor(entry.saved?.message.thread ?? entry.alert!.task.thread), root: model.page?.root.id ?? family.task.thread, creator: creator(for: entry, entries: chronology.entries), read: { if let item = entry.saved { detail = item } })
                        }
                    }
                }.padding(16)
                if chronology.otherAlerts > 0 {
                    HStack {
                        Text("\(chronology.otherAlerts) matching alerts are outside the loaded message history.").font(.system(size: 11)).foregroundStyle(Color.inboxSecondary)
                        Spacer(minLength: 0)
                        Button("Show alerts", action: showAlerts).controlSize(.small)
                    }.padding(12)
                }
                if let captured = model.page?.capturedAt { Text("Updated " + DisplayTime.full(captured)).font(.system(size: 9)).foregroundStyle(Color.inboxSecondary).padding(12) }
            }
        }.background(Color.blue.opacity(0.01), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.blue.opacity(0.18)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .sheet(item: $detail) { item in SavedMessageDetails(inbox: inbox, item: item, actor: actor(item.message.thread)) }
            .task(id: family.id) {
                guard !model.preview else { return }
                model.load(family.task)
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                    if !collapsed { model.load(family.task) }
                }
            }
            .onDisappear { model.cancel() }
    }
    private func creator(for entry: TranscriptEntry, entries: [TranscriptEntry]) -> String? {
        guard let thread = entry.saved?.message.thread, let owner = actor(thread), owner.isSubagent,
              !model.routing.contains(where: { $0.kind == "spawn_agent" && $0.recipient == thread }),
              entries.first(where: { $0.saved?.message.thread == thread })?.id == entry.id,
              let parent = model.page?.actors.first(where: { $0.id == owner.parent }) else { return nil }
        return parent.id == model.page?.root.id && !parent.isSubagent ? "Main chat" : parent.name
    }
}

struct SavedTranscriptRow: View {
    @ObservedObject var inbox: Inbox
    let entry: TranscriptEntry
    let actor: SavedMapActor?
    let root: String
    var creator: String? = nil
    let read: () -> Void
    private var input: Bool { entry.saved?.message.role == "user" }
    private var agent: Bool { actor?.isSubagent ?? (entry.alert?.task.thread != root) }
    private var tint: Color { input ? .inboxSecondary : agent ? .purple : .inboxAccent }
    private var author: String {
        let name = actor?.name ?? entry.alert?.task.agentNickname ?? entry.alert?.task.displayTitle ?? "Unknown conversation"
        if input { return "INPUT → " + (agent ? name : "Main chat") }
        return agent ? "SUBAGENT · " + name : "MAIN CHAT"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(author).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).lineLimit(2)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
                Spacer(minLength: 6)
                Text(entry.at.map(TranscriptTime.label) ?? "Time unknown").font(.system(size: 11)).foregroundStyle(Color.inboxSecondary).lineLimit(1).help(entry.at.map(DisplayTime.full) ?? "Timestamp was not recorded")
            }
            if let creator { Label("Created by " + creator, systemImage: "person.2").font(.system(size: 10)).foregroundStyle(Color.inboxSecondary).help("Recorded subagent ownership. This label does not assign a creation time or a message recipient.") }
            if let item = entry.saved {
                Text(item.message.label + (item.turnNumber.map { " · Turn \($0)" } ?? " · Turn unknown")).font(.system(size: 10)).foregroundStyle(Color.inboxSecondary)
                Text(item.message.preview.isEmpty ? "[No text in this saved message]" : item.message.preview).font(.system(size: 12)).lineSpacing(4).lineLimit(3).textSelection(.enabled)
                HStack {
                    Button("Read message", action: read).buttonStyle(.plain).foregroundStyle(tint).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                }
                ForEach(entry.notices) { notice in alertActions(notice, showBody: notice.notice.kind == "question") }
            } else if let alert = entry.alert {
                Text("ALERT · " + alert.notice.label).font(.system(size: 10, weight: .medium)).foregroundStyle(alert.notice.tint)
                Text(alert.notice.body).font(.system(size: 12)).lineLimit(3).textSelection(.enabled)
                alertActions(alert, showBody: false)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.38), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.12)))
            .accessibilityElement(children: .contain)
    }
    private func alertActions(_ notice: StoredNotice, showBody: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if showBody { Text(notice.notice.body).font(.system(size: 11)).lineLimit(2) }
            HStack(spacing: 7) {
                Label(notice.notice.label, systemImage: notice.notice.symbol).foregroundStyle(notice.notice.tint)
                Text(notice.seen ? "Seen" : "Unseen").foregroundStyle(Color.inboxSecondary)
                Spacer(minLength: 0)
                Button("Open") { inbox.open(notice) }
                Button(notice.needsAttention ? "Done" : "Reopen") { inbox.perform(notice.needsAttention ? .done : .reopen, ids: [notice.id]) }
            }.font(.system(size: 10)).controlSize(.small)
        }
    }
}

struct SavedRoutingRow: View {
    let route: SavedMapHandoff
    let actors: [SavedMapActor]
    let root: String
    @State private var expanded = false
    private var spawned: Bool { route.kind == "spawn_agent" }
    private var tint: Color { spawned ? .purple : .orange }
    private var action: String {
        switch route.kind {
        case "spawn_agent": return "Subagent created"
        case "followup_task": return "Task send recorded"
        case "resume_agent": return "Subagent resumed"
        default: return "Message send recorded"
        }
    }
    private func name(_ id: String) -> String {
        guard let actor = actors.first(where: { $0.id == id }) else { return String(id.prefix(8)) }
        return id == root && !actor.isSubagent ? "Main chat" : actor.name
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(action, systemImage: spawned ? "person.badge.plus" : "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                Spacer(minLength: 6)
                Text(TranscriptTime.label(route.at)).font(.system(size: 10)).foregroundStyle(Color.inboxSecondary).help(DisplayTime.full(route.at))
            }
            HStack(spacing: 8) {
                Text(name(route.sender)).lineLimit(2).help(name(route.sender))
                Image(systemName: "arrow.right").foregroundStyle(tint).accessibilityLabel("to")
                Text(name(route.recipient)).lineLimit(2).help(name(route.recipient))
                Spacer(minLength: 0)
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.plain).foregroundStyle(Color.inboxSecondary).help("Show the recorded message and evidence")
                    .accessibilityLabel((expanded ? "Hide" : "Show") + " recorded routing evidence")
            }.font(.system(size: 12, weight: .medium))
            if expanded {
                Divider()
                Text(route.preview.isEmpty ? "No message text was included in this record." : route.preview)
                    .font(.system(size: 12)).lineSpacing(4).textSelection(.enabled)
                if !route.preview.isEmpty { Text("Saved prompt preview").font(.system(size: 10)).foregroundStyle(Color.inboxSecondary) }
                Text("This record identifies the sender’s turn and recipient chat. It does not establish delivery to a particular recipient turn or message.")
                    .font(.system(size: 11)).foregroundStyle(Color.inboxSecondary)
                DisclosureGroup("Source evidence") {
                    Text(route.evidence + "\nCall: " + route.callID + "\nSender turn: " + route.senderTurn + "\nSource: " + route.source + (route.byteOffset.map { "\nByte offset: \($0)" } ?? ""))
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }.font(.system(size: 11))
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.18)))
            .accessibilityElement(children: .contain)
    }
}

struct SavedMessageDetails: View {
    @ObservedObject var inbox: Inbox
    let item: SavedTranscriptMessage
    let actor: SavedMapActor?
    @State private var full: ConversationMapReader.FullMessage?
    @State private var error = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text((item.message.role == "user" ? "Input to " : actor?.isSubagent == true ? "Subagent · " : "Main chat · ") + (actor?.name ?? item.message.thread)).font(.system(size: 17, weight: .semibold)).lineLimit(2)
            Text(item.message.label + (item.turnNumber.map { " · Turn \($0)" } ?? "") + " · " + (item.message.at.map(DisplayTime.full) ?? "Time unknown")).font(.system(size: 11)).foregroundStyle(Color.inboxSecondary)
            ScrollView { Text(full?.text ?? item.message.preview).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 180)
            if full?.truncated == true { Text("This message exceeds the 1 MiB detail limit. Open its chat for the full source.").font(.system(size: 11)).foregroundStyle(.orange) }
            if !error.isEmpty { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Button("Open chat") { inbox.open(TaskIdentity(thread: item.message.thread, title: actor?.name ?? item.message.thread)) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.controlSize(.small)
        }.padding(22).frame(minWidth: 480, idealWidth: 640, minHeight: 350)
            .task {
                let message = item.message
                let result = await Task.detached(priority: .userInitiated) { Result { try ConversationMapReader.message(message) } }.value
                switch result { case .success(let value): full = value; case .failure(let failure): error = failure.localizedDescription }
            }
    }
}
