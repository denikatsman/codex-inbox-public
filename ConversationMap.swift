import AppKit
import SwiftUI
import Foundation

struct SavedMapActor: Decodable, Identifiable, Sendable {
    var id: String
    var name: String
    var isSubagent: Bool
    var parent: String?
    var path: String?
    var rollout: String?
}
struct SavedMapTurn: Decodable, Identifiable, Sendable {
    var id: String
    var thread: String
    var turn: String
    var status: String
    var start: Double?
    var end: Double?
    var ordinal: Int
    var number: Int
}
struct SavedMapMessage: Decodable, Identifiable, Sendable {
    var id: String
    var thread: String
    var turn: String
    var item: String
    var at: Double?
    var role: String
    var phase: String?
    var preview: String
    var ordinal: Int
    var label: String {
        role == "user" ? "Input message" : phase == "final_answer" ? "Final reply" : phase == "commentary" ? "Progress message" : "Assistant message"
    }
}
struct SavedMapHandoff: Decodable, Identifiable, Sendable {
    var id: String
    var sender: String
    var senderTurn: String
    var recipient: String
    var at: Double
    var kind: String
    var callID: String
    var preview: String
    var source: String
    var byteOffset: Int64?
    var evidence: String
    var label: String {
        switch kind {
        case "spawn_agent": return "Spawn recorded"
        case "followup_task", "resume_agent": return "Follow-up recorded"
        default: return "Message handoff recorded"
        }
    }
}
struct ConversationMapSnapshot: Decodable, Sendable {
    var root: SavedMapActor
    var requested: String
    var actors: [SavedMapActor]
    var familyCount: Int
    var turns: [SavedMapTurn]
    var messages: [SavedMapMessage]
    var handoffs: [SavedMapHandoff]
    var start: Double
    var end: Double
    var capturedAt: Double
    var warnings: [String]
    var source: String
    var latestMessage: SavedMapMessage? {
        messages.filter { $0.at != nil }.max { ($0.at ?? 0) < ($1.at ?? 0) } ?? messages.first
    }
}

enum ConversationMapReader {
    struct ReaderFailure: Decodable { var error: String }
    static func run(_ arguments: [String]) throws -> Data {
        let bundled = Bundle.main.url(forResource: "conversation_map", withExtension: "py")
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("conversation_map.py")
        guard let script = bundled ?? (FileManager.default.fileExists(atPath: development.path) ? development : nil) else {
            throw StoreError.database("The saved-history reader is missing from this build.")
        }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", script.path] + arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard data.count + chunk.count <= 16 * 1024 * 1024 else {
                process.terminate()
                throw StoreError.database("Saved-history output exceeded its read limit. Choose a shorter window.")
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        if let failure = try? JSONDecoder().decode(ReaderFailure.self, from: data) { throw StoreError.database(failure.error) }
        guard process.terminationStatus == 0 else { throw StoreError.database("The saved-history reader could not complete.") }
        return data
    }
    static func load(thread: String, hours: Double, now: Double = Date().timeIntervalSince1970) throws -> ConversationMapSnapshot {
        try JSONDecoder().decode(ConversationMapSnapshot.self, from: run(["--thread", thread, "--since", String(now - hours * 3600), "--until", String(now)]))
    }
    struct FullMessage: Decodable { var text: String; var truncated: Bool }
    static func message(_ value: SavedMapMessage) throws -> FullMessage {
        try JSONDecoder().decode(FullMessage.self, from: run(["--thread", value.thread, "--message-turn", value.turn, "--message-item", value.item]))
    }
}

@MainActor final class ConversationMapModel: ObservableObject {
    @Published var snapshot: ConversationMapSnapshot?
    @Published var loading = false
    @Published var error = ""
    @Published var selectedMessage: SavedMapMessage?
    @Published var selectedHandoff: SavedMapHandoff?
    @Published var fullText: String?
    @Published var textTruncated = false
    private let queue = DispatchQueue(label: "local.codex.inbox.saved-map", qos: .userInitiated)
    private var generation = 0
    private var selectionGeneration = 0
    private var loadedThread: String?
    let preview: Bool
    init(preview: ConversationMapSnapshot? = nil, tracePreview: Bool = false) {
        self.preview = preview != nil; snapshot = preview
        if tracePreview, let handoff = preview?.handoffs.max(by: { $0.at < $1.at }) { selectedHandoff = handoff }
        else { selectedMessage = preview?.latestMessage }
    }
    func load(_ task: TaskIdentity, hours: Double) {
        guard !preview else { return }
        generation += 1; let request = generation
        guard task.host == "local" else { error = "This cloud conversation has no local saved transcript."; snapshot = nil; loading = false; return }
        loading = true; error = ""
        if loadedThread != task.thread {
            snapshot = nil; selectedMessage = nil; selectedHandoff = nil; fullText = nil
            selectionGeneration += 1; loadedThread = task.thread
        }
        queue.async { [weak self] in
            let result = Result { try ConversationMapReader.load(thread: task.thread, hours: hours) }
            Task { @MainActor [weak self] in
                guard let self, request == self.generation else { return }
                self.loading = false
                switch result {
                case .success(let value):
                    self.snapshot = value
                    if let old = self.selectedHandoff, let current = value.handoffs.first(where: { $0.id == old.id }) { self.select(current) }
                    else if let old = self.selectedMessage, let current = value.messages.first(where: { $0.id == old.id }) { self.selectedMessage = current }
                    else if let message = value.latestMessage { self.select(message) }
                    else { self.selectedMessage = nil; self.selectedHandoff = nil; self.fullText = nil }
                case .failure(let failure): self.error = failure.localizedDescription; self.snapshot = nil
                }
            }
        }
    }
    func select(_ message: SavedMapMessage) {
        selectedMessage = message; selectedHandoff = nil; fullText = nil; textTruncated = false
        selectionGeneration += 1; let request = selectionGeneration
        guard !preview else { return }
        queue.async { [weak self] in
            let result = Result { try ConversationMapReader.message(message) }
            Task { @MainActor [weak self] in
                guard let self, request == self.selectionGeneration, self.selectedMessage?.id == message.id else { return }
                switch result {
                case .success(let value): self.fullText = value.text; self.textTruncated = value.truncated
                case .failure(let failure): self.error = failure.localizedDescription
                }
            }
        }
    }
    func select(_ handoff: SavedMapHandoff) {
        selectionGeneration += 1; selectedMessage = nil; selectedHandoff = handoff; fullText = nil
    }
}

struct ConversationMapView: View {
    @ObservedObject var inbox: Inbox
    @Binding var requested: TaskIdentity?
    @StateObject private var model: ConversationMapModel
    @State private var hours: Double = 2
    @State private var laneLimit = 10
    init(inbox: Inbox, requested: Binding<TaskIdentity?>, preview: ConversationMapSnapshot? = nil, tracePreview: Bool = false) {
        self.inbox = inbox; _requested = requested; _model = StateObject(wrappedValue: ConversationMapModel(preview: preview, tracePreview: tracePreview))
    }
    private var candidates: [StoredTask] {
        let catalog = inbox.snapshot.taskCatalog
        let parents = Set(catalog.values.filter(\.isSubagent).compactMap(\.parentKey))
        return catalog.values.filter {
            $0.task.host == "local" && !$0.isSubagent && (inbox.query.project == nil || $0.task.projectKey == inbox.query.project)
        }.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            if parents.contains($0.id) != parents.contains($1.id) { return parents.contains($0.id) }
            return ($0.observedAt ?? 0, $0.task.displayTitle) > ($1.observedAt ?? 0, $1.task.displayTitle)
        }
    }
    private var task: TaskIdentity? { requested ?? candidates.first?.task }
    private var loadID: String { (task?.key ?? "") + ":" + String(hours) }
    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let snapshot = model.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(snapshot.root.name).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                                Text("\(snapshot.actors.count) conversations · \(snapshot.turns.count) saved turns · \(snapshot.messages.count) messages · \(snapshot.handoffs.count) recorded handoffs")
                                    .font(.system(size: 11)).foregroundStyle(Color.inboxSecondary)
                                Text("Saved snapshot · " + DisplayTime.full(snapshot.capturedAt)).font(.system(size: 10)).foregroundStyle(Color.inboxSecondary)
                            }
                            Spacer()
                        }
                        Text("Shared clock · Click a message or handoff · Turn numbers belong to each conversation")
                            .font(.system(size: 11)).foregroundStyle(Color.inboxSecondary)
                        HStack(spacing: 14) {
                            Label("Turn", systemImage: "rectangle.fill")
                            Label("Input", systemImage: "circle")
                            Label("Assistant", systemImage: "circle.fill")
                            Label("Recorded call", systemImage: "diamond.fill").foregroundStyle(.orange)
                        }.font(.system(size: 10)).foregroundStyle(Color.inboxSecondary)
                        ConversationMapChart(snapshot: snapshot, model: model, laneLimit: laneLimit)
                        let unknown = snapshot.messages.filter { $0.at == nil }.count
                        if unknown > 0 {
                            Text("\(unknown) messages have no saved timestamp. They remain available in the message picker below.")
                                .font(.system(size: 11)).foregroundStyle(Color.inboxSecondary)
                        }
                        if snapshot.actors.count > laneLimit {
                            Button("Show more subagent lanes (\(snapshot.actors.count - laneLimit) hidden)") { laneLimit += 10 }.controlSize(.small)
                        }
                        if snapshot.familyCount > snapshot.actors.count {
                            Text("\(snapshot.familyCount - snapshot.actors.count) other saved family threads have no turns or handoffs in this window.")
                                .font(.system(size: 11)).foregroundStyle(Color.inboxSecondary)
                        }
                        if !snapshot.warnings.isEmpty {
                            Text(snapshot.warnings.joined(separator: " ")).font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        messageSelector(snapshot)
                        handoffSelector(snapshot)
                        details(snapshot)
                    }.padding(18)
                }
            } else {
                VStack(spacing: 10) {
                    if model.loading { ProgressView() }
                    Text(model.loading ? "Reading saved turns and messages…" : model.error.isEmpty ? "Choose a saved parent chat to map its conversations." : model.error)
                        .font(.system(size: 13)).foregroundStyle(Color.inboxSecondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: loadID) { if let task { model.load(task, hours: hours) } }
    }
    private var controls: some View {
        HStack(spacing: 10) {
            Label("Conversation map", systemImage: "point.3.connected.trianglepath.dotted").font(.system(size: 12, weight: .semibold))
            Menu {
                ForEach(candidates) { row in Button(row.task.displayTitle) { requested = row.task; laneLimit = 10 } }
            } label: { Text(model.snapshot?.root.name ?? task?.displayTitle ?? "Choose parent chat").lineLimit(1) }
                .menuStyle(.borderlessButton).frame(maxWidth: 280)
            Spacer(minLength: 0)
            Picker("Window", selection: $hours) {
                Text("30 min").tag(0.5); Text("2 hours").tag(2.0); Text("6 hours").tag(6.0); Text("24 hours").tag(24.0)
            }.labelsHidden().frame(width: 100)
            Button { if let task { model.load(task, hours: hours) } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.loading || model.preview).help("Refresh saved history")
            if model.loading { ProgressView().controlSize(.small) }
        }.controlSize(.small).padding(.horizontal, 18).padding(.vertical, 12)
    }
    private func actor(_ id: String, in snapshot: ConversationMapSnapshot) -> SavedMapActor? { snapshot.actors.first { $0.id == id } }
    private func messageSelector(_ snapshot: ConversationMapSnapshot) -> some View {
        HStack {
            Text("Message").font(.system(size: 11, weight: .medium))
            Picker("Saved message", selection: Binding(get: { model.selectedMessage?.id ?? "" }, set: { id in if let message = snapshot.messages.first(where: { $0.id == id }) { model.select(message) } })) {
                Text("Choose a message").tag("")
                ForEach(snapshot.messages.sorted { ($0.at ?? -.infinity) > ($1.at ?? -.infinity) }) { message in
                    Text((message.at.map { DisplayTime.ago($0, now: snapshot.end) } ?? "Time unknown") + " · " + (actor(message.thread, in: snapshot)?.name ?? message.thread.prefix(8).description) + " · " + message.label).tag(message.id)
                }
            }.labelsHidden()
            Spacer(minLength: 0)
        }.controlSize(.small)
    }
    private func handoffSelector(_ snapshot: ConversationMapSnapshot) -> some View {
        HStack {
            Text("Handoff").font(.system(size: 11, weight: .medium))
            Picker("Recorded handoff", selection: Binding(get: { model.selectedHandoff?.id ?? "" }, set: { id in if let handoff = snapshot.handoffs.first(where: { $0.id == id }) { model.select(handoff) } })) {
                Text(snapshot.handoffs.isEmpty ? "No handoff evidence loaded for this window" : "Choose a recorded call to trace").tag("")
                ForEach(snapshot.handoffs.sorted { $0.at > $1.at }) { handoff in
                    Text(DisplayTime.ago(handoff.at, now: snapshot.end) + " · " + handoff.label + " → " + (actor(handoff.recipient, in: snapshot)?.name ?? handoff.recipient)).tag(handoff.id)
                }
            }.labelsHidden()
            Spacer(minLength: 0)
        }.controlSize(.small)
    }
    @ViewBuilder private func details(_ snapshot: ConversationMapSnapshot) -> some View {
        if let handoff = model.selectedHandoff {
            VStack(alignment: .leading, spacing: 8) {
                Text(handoff.label).font(.system(size: 13, weight: .semibold))
                Text((actor(handoff.sender, in: snapshot)?.name ?? handoff.sender) + " → " + (actor(handoff.recipient, in: snapshot)?.name ?? handoff.recipient))
                    .font(.system(size: 12))
                Text(DisplayTime.full(handoff.at)).font(.system(size: 11)).foregroundStyle(Color.inboxSecondary)
                Text(handoff.preview.isEmpty ? "No message text was included in this call." : handoff.preview).font(.system(size: 12)).textSelection(.enabled)
                if !handoff.preview.isEmpty { Text("Saved call prompt preview").font(.system(size: 10)).foregroundStyle(Color.inboxSecondary) }
                Text("The source records the sender’s own turn and recipient thread. It does not identify a recipient turn or prove delivery to a specific child message.")
                    .font(.system(size: 11)).foregroundStyle(Color.inboxSecondary)
                DisclosureGroup("Recorded evidence") {
                    Text(handoff.evidence + "\nCall: " + handoff.callID + "\nSender turn: " + handoff.senderTurn + "\nSource: " + handoff.source + (handoff.byteOffset.map { "\nByte offset: \($0)" } ?? ""))
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }.font(.system(size: 11))
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        } else if let message = model.selectedMessage {
            let owner = actor(message.thread, in: snapshot)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text((owner?.isSubagent == true ? "Subagent · " : "Parent chat · ") + (owner?.name ?? message.thread)).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Button("Open chat") { inbox.open(TaskIdentity(thread: message.thread, title: owner?.name ?? message.thread)) }.controlSize(.small)
                }
                let turn = snapshot.turns.first { $0.thread == message.thread && $0.turn == message.turn }
                Text(message.label + (turn.map { " · Turn \($0.number)" } ?? "") + " · " + (message.at.map(DisplayTime.full) ?? "Time unknown")).font(.system(size: 11)).foregroundStyle(Color.inboxSecondary)
                Text(model.fullText ?? message.preview).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if model.fullText == nil { Text("Saved message preview").font(.system(size: 10)).foregroundStyle(Color.inboxSecondary) }
                if model.textTruncated { Text("This message exceeds the 1 MiB detail limit. Open its chat to inspect the full source.").font(.system(size: 11)).foregroundStyle(.orange) }
                if !model.error.isEmpty { Text(model.error).font(.system(size: 11)).foregroundStyle(.orange) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.inboxAccent.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

struct ConversationMapChart: View {
    let snapshot: ConversationMapSnapshot
    @ObservedObject var model: ConversationMapModel
    let laneLimit: Int
    private var actors: [SavedMapActor] { Array(snapshot.actors.prefix(laneLimit)) }
    private let left: CGFloat = 150
    private let top: CGFloat = 36
    private let row: CGFloat = 78
    private var height: CGFloat { top + CGFloat(actors.count) * row + 42 }
    private func x(_ time: Double, width: CGFloat) -> CGFloat {
        let span = max(1, snapshot.end - snapshot.start)
        return left + 12 + CGFloat(min(1, max(0, (time - snapshot.start) / span))) * max(1, width - left - 30)
    }
    private func y(_ actor: Int) -> CGFloat { top + CGFloat(actor) * row + 37 }
    private func lane(_ id: String) -> Int? { actors.firstIndex { $0.id == id } }
    private func turnNumber(_ turn: SavedMapTurn) -> Int {
        turn.number
    }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let plotWidth = max(1, size.width - left - 18)
                    for index in 0...4 {
                        let at = snapshot.start + (snapshot.end - snapshot.start) * Double(index) / 4
                        let px = x(at, width: size.width)
                        var grid = Path(); grid.move(to: CGPoint(x: px, y: 24)); grid.addLine(to: CGPoint(x: px, y: height - 30))
                        context.stroke(grid, with: .color(.inboxSecondary.opacity(0.18)), lineWidth: 1)
                        let text = Text(Date(timeIntervalSince1970: at), format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundColor(.inboxSecondary)
                        context.draw(text, at: CGPoint(x: min(size.width - 26, max(left + 24, px)), y: 12))
                    }
                    for (index, actor) in actors.enumerated() {
                        let center = y(index)
                        let tint: Color = actor.isSubagent ? .purple : .blue
                        var guide = Path(); guide.move(to: CGPoint(x: left, y: center + 32)); guide.addLine(to: CGPoint(x: left + plotWidth, y: center + 32))
                        context.stroke(guide, with: .color(.inboxSecondary.opacity(0.12)), lineWidth: 1)
                        for turn in snapshot.turns where turn.thread == actor.id {
                            guard let began = turn.start else { continue }
                            let lastMessage = snapshot.messages.filter { $0.thread == turn.thread && $0.turn == turn.turn }.compactMap(\.at).max()
                            let horizon = turn.end ?? max(began, lastMessage ?? began)
                            let rect = CGRect(x: x(began, width: size.width), y: center - 22, width: max(3, x(horizon, width: size.width) - x(began, width: size.width)), height: 40)
                            let selected = model.selectedMessage?.thread == turn.thread && model.selectedMessage?.turn == turn.turn || model.selectedHandoff?.sender == turn.thread && model.selectedHandoff?.senderTurn == turn.turn
                            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(tint.opacity(selected ? 0.28 : 0.13)))
                            if rect.width > 50 {
                                let text = Text("T\(turnNumber(turn))" + (turn.end == nil ? " · ?" : "")).font(.system(size: 10)).foregroundColor(.primary)
                                context.draw(text, at: CGPoint(x: rect.minX + 7, y: center - 8), anchor: .leading)
                            }
                        }
                        for message in snapshot.messages where message.thread == actor.id {
                            guard let at = message.at else { continue }
                            let px = x(at, width: size.width), py = center + 7
                            let dot = Path(ellipseIn: CGRect(x: px - 3.5, y: py - 3.5, width: 7, height: 7))
                            if message.role == "user" { context.stroke(dot, with: .color(tint), lineWidth: 1.5) }
                            else { context.fill(dot, with: .color(tint.opacity(message.phase == "final_answer" ? 1 : 0.55))) }
                            if model.selectedMessage?.id == message.id { context.stroke(Path(ellipseIn: CGRect(x: px - 7, y: py - 7, width: 14, height: 14)), with: .color(.primary), lineWidth: 1.5) }
                        }
                    }
                    for link in snapshot.handoffs {
                        guard let sender = lane(link.sender), let recipient = lane(link.recipient) else { continue }
                        let px = x(link.at, width: size.width)
                        let point = CGPoint(x: px, y: y(sender) + 7)
                        var diamond = Path(); diamond.move(to: CGPoint(x: point.x, y: point.y - 5)); diamond.addLine(to: CGPoint(x: point.x + 5, y: point.y)); diamond.addLine(to: CGPoint(x: point.x, y: point.y + 5)); diamond.addLine(to: CGPoint(x: point.x - 5, y: point.y)); diamond.closeSubpath()
                        context.fill(diamond, with: .color(.orange.opacity(0.8)))
                        let selected = model.selectedHandoff?.id == link.id
                        if selected {
                            // The saved call identifies a recipient thread, not a
                            // child turn. Terminate on its lane, away from bars.
                            let target = CGPoint(x: px, y: y(recipient) + 29)
                            var path = Path(); path.move(to: point); path.addLine(to: target)
                            context.stroke(path, with: .color(.orange.opacity(0.85)), lineWidth: 1.5)
                            let tipY = target.y + (target.y > point.y ? -6 : 6)
                            var tip = Path(); tip.move(to: CGPoint(x: target.x - 4, y: tipY)); tip.addLine(to: target); tip.addLine(to: CGPoint(x: target.x + 4, y: tipY))
                            context.stroke(tip, with: .color(.orange), lineWidth: 1.5)
                        }
                    }
                    if let selected = model.selectedMessage, let at = selected.at {
                        var cursor = Path(); cursor.move(to: CGPoint(x: x(at, width: size.width), y: 24)); cursor.addLine(to: CGPoint(x: x(at, width: size.width), y: height - 30))
                        context.stroke(cursor, with: .color(.inboxSecondary.opacity(0.4)), lineWidth: 1)
                    }
                    context.draw(Text("Recorded local time · ? = turn end not recorded").font(.system(size: 10)).foregroundColor(.inboxSecondary), at: CGPoint(x: left + plotWidth / 2, y: height - 12))
                }
                forEachLabels
                Color.clear.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { value in
                    let point = value.location
                    guard point.x >= left else { return }
                    var nearest: (Double, SavedMapMessage?, SavedMapHandoff?)?
                    for message in snapshot.messages {
                        guard let at = message.at, let index = lane(message.thread) else { continue }
                        let distance = hypot(Double(x(at, width: width) - point.x), Double(y(index) + 7 - point.y))
                        if nearest == nil || distance < nearest!.0 { nearest = (distance, message, nil) }
                    }
                    for link in snapshot.handoffs {
                        guard let index = lane(link.sender) else { continue }
                        let distance = hypot(Double(x(link.at, width: width) - point.x), Double(y(index) + 7 - point.y))
                        if nearest == nil || distance < nearest!.0 { nearest = (distance, nil, link) }
                    }
                    if let nearest, nearest.0 < 24 {
                        if let message = nearest.1 { model.select(message) }
                        else if let link = nearest.2 { model.select(link) }
                    }
                })
            }
        }.frame(height: height)
            .accessibilityLabel("Saved parent and subagent conversations on one time axis. Use the message picker for keyboard access.")
    }
    private var forEachLabels: some View {
        ForEach(Array(actors.enumerated()), id: \.element.id) { index, actor in
            VStack(alignment: .leading, spacing: 4) {
                Text(actor.isSubagent ? "SUBAGENT" : "PARENT CHAT").font(.system(size: 9, weight: .semibold)).foregroundStyle(actor.isSubagent ? Color.purple : .blue)
                Text(actor.name).font(.system(size: 11, weight: .medium)).lineLimit(2).help(actor.name + "\nThread: " + actor.id)
                if actor.isSubagent, let parent = snapshot.actors.first(where: { $0.id == actor.parent }), parent.isSubagent {
                    Text("Child of " + parent.name).font(.system(size: 9)).foregroundStyle(Color.inboxSecondary).lineLimit(1)
                }
            }.frame(width: left - 14, alignment: .leading).position(x: (left - 14) / 2, y: y(index))
        }
    }
}
