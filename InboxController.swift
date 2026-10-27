import AppKit
import SwiftUI
import UserNotifications
import Darwin

private final class StorageWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "local.codex.inbox.storage", qos: .utility)
    var store: InboxStore?
    var failed = false
    func open(path: String, legacy: [URL], time: EventTime, completion: @escaping @MainActor (Result<Double, Error>) -> Void) {
        queue.async {
            let result = Result<Double, Error> {
                let store = try InboxStore(path: path)
                try store.migrateLegacy(files: legacy, at: time)
                try store.invalidateRuntime()
                self.store = store
                return Double(try store.metadata("last_run") ?? "") ?? time.deviceAt
            }
            if case .failure = result { self.failed = true }
            Task { @MainActor in completion(result) }
        }
    }
    func run<T>(_ job: @escaping (InboxStore) throws -> T, completion: @escaping @MainActor (Result<T, Error>) -> Void) {
        queue.async {
            let result = Result<T, Error> {
                guard !self.failed, let store = self.store else { throw StoreError.database("Activity storage is unavailable. Restart the inbox after resolving the storage error.") }
                return try job(store)
            }
            if case .failure = result { self.failed = true }
            Task { @MainActor in completion(result) }
        }
    }
    func flush(lastRun: Double) {
        queue.async { if !self.failed { try? self.store?.setMetadata("last_run", String(lastRun)) } }
    }
}

/// One envelope is handed to the storage consumer at a time. The background
/// reader waits for its commit; the main actor never waits on pipe I/O or SQLite.
final class CollectorPipeReader: @unchecked Sendable {
    static let recordLimit = 16 * 1024 * 1024
    private let queue = DispatchQueue(label: "local.codex.inbox.pipe", qos: .utility)
    func start(_ handle: FileHandle, consume: @escaping (Data, @escaping () -> Void) -> Void, failure: @escaping (String) -> Void) {
        queue.async {
            var pending = Data()
            do {
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    // FileHandle.read(upToCount:) may fill the request on a pipe.
                    // POSIX read returns available bytes, including short quiet frames.
                    let count = Darwin.read(handle.fileDescriptor, &chunk, chunk.count)
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw StoreError.database("Collector pipe read failed: " + String(cString: strerror(errno)))
                    }
                    pending.append(contentsOf: chunk.prefix(count))
                    while let newline = pending.firstIndex(of: 10) {
                        guard pending.distance(from: pending.startIndex, to: newline) <= Self.recordLimit else { throw StoreError.database("Collector envelope exceeds 16 MiB; checkpoints paused.") }
                        let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                        let committed = DispatchSemaphore(value: 0)
                        consume(line) { committed.signal() }
                        committed.wait()
                    }
                    guard pending.count <= Self.recordLimit else { throw StoreError.database("Collector envelope exceeds 16 MiB; checkpoints paused.") }
                }
                if !pending.isEmpty { failure("Collector stopped during an envelope; checkpoints paused.") }
            } catch { failure(error.localizedDescription) }
            try? handle.close()
        }
    }
}

@MainActor final class Inbox: ObservableObject {
    @Published private(set) var snapshot = InboxSnapshot()
    @Published var query = InboxQuery() {
        didSet {
            if query.selectionScope != oldValue.selectionScope { selectedIDs = []; detailNotice = nil }
            if query != oldValue { refresh() }
        }
    }
    @Published var selectedIDs: Set<String> = []
    @Published var detailNotice: StoredNotice?
    @Published private(set) var batchBusy = false
    @Published var actionMessage = ""
    @Published private(set) var lastUndo: NoticeUndo?
    @Published var byProject = false
    @Published var historyTaskTitle: String?
    @Published var connected = false
    @Published var history = false
    @Published var tasks = 0
    @Published var liveTasks = 0
    @Published var warning = ""
    @Published var storageError = ""
    @Published var sourceError = ""
    @Published var notificationPermission = ""
    @Published private(set) var lastCollectorContactAt: Double?
    @Published private(set) var ready = false
    @Published private(set) var queuedOpens: Set<URL> = []
    @Published var sound = true {
        didSet { defaults?.set(sound, forKey: "sound") }
    }
    @Published var alertSound: InboxAlertSound = .glass {
        didSet { defaults?.set(alertSound.rawValue, forKey: "alertSound") }
    }
    let opener: TaskOpener
    let clock: TimelineClock
    let clockCheck: ClockCheck
    var changed: (() -> Void)?
    var showAccessSettings: (() -> Void)?
    private let worker = StorageWorker()
    private let directory: URL
    private let demo: Bool
    private let defaults: UserDefaults?
    private let alertsEnabled: Bool
    private var demoStore: InboxStore?
    private var process: Process?
    private var pipe: Pipe?
    private var lifetime: Pipe?
    private let reader = CollectorPipeReader()
    @Published private(set) var bannerInFlight: Set<String> = []
    typealias BannerScheduler = (Notice, String, @escaping (String?) -> Void) -> Void
    private var bannerAttempts: [String: String] = [:]
    private let bannerScheduler: BannerScheduler
    private let soundPlayer: (String) -> Void
    private var buffer = Data()
    private var refreshJob: DispatchWorkItem?
    private var refreshInFlight = false
    private var refreshRequested = false
    private var activityRefreshTimer: Timer?
    private var retry: DispatchWorkItem?
    private var since = Date().timeIntervalSince1970
    private var requestedStart = false
    private var stopped = false
    private var safeToAcknowledgeSource = true
    private var lastSound = ContinuousClock.now - .seconds(10)
    private var openAttempts: [URL: String] = [:]
    var pendingCount: Int { snapshot.pending }
    var databaseURL: URL { directory.appendingPathComponent("activity.sqlite") }

    init(demo: Bool = false, directory: URL? = nil, opener: TaskOpener? = nil, clock: TimelineClock = TimelineClock(), alertsEnabled: Bool = true, bannerScheduler: BannerScheduler? = nil, soundPlayer: @escaping (String) -> Void = { NSSound(named: NSSound.Name($0))?.play() }, defaults: UserDefaults? = .standard) {
        self.demo = demo; self.alertsEnabled = alertsEnabled; self.opener = opener ?? TaskOpener(); self.clock = clock
        self.clockCheck = ClockCheck(clock: clock)
        self.soundPlayer = soundPlayer
        self.defaults = demo ? nil : defaults
        sound = defaults?.object(forKey: "sound") as? Bool ?? true
        alertSound = defaults?.string(forKey: "alertSound").flatMap(InboxAlertSound.init(rawValue:)) ?? .glass
        self.bannerScheduler = bannerScheduler ?? { event, attempt, done in
            let content = UNMutableNotificationContent()
            content.title = event.label + " · " + event.title; content.body = String(event.body.prefix(240)); content.userInfo = ["noticeID": event.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil)) { done($0?.localizedDescription) }
        }
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Codex Inbox")
        if demo {
            do { try makeDemo(); ready = true; connected = true; history = true; liveTasks = 12; tasks = 263; lastCollectorContactAt = clock.stamp().at; refresh() }
            catch { storageError = error.localizedDescription }
            return
        }
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let files = ["inbox-v1-preserved.json", "inbox.json"].map { self.directory.appendingPathComponent($0) }
            worker.open(path: databaseURL.path, legacy: files, time: clock.stamp()) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let lastRun):
                    self.since = lastRun > 0 ? lastRun : self.since
                    self.ready = true; self.refresh()
                    if self.requestedStart { self.launchCollector() }
                case .failure(let error): self.storageError = "History could not be opened. Existing files were preserved. " + error.localizedDescription
                }
            }
        } catch { storageError = error.localizedDescription }
    }

    private func submit<T>(_ job: @escaping (InboxStore) throws -> T, completion: (@MainActor (T) -> Void)? = nil) {
        if let demoStore {
            do { let value = try job(demoStore); refresh(); completion?(value) }
            catch { storageError = error.localizedDescription }
            return
        }
        worker.run(job) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value): self.refresh(); completion?(value)
            case .failure(let error):
                self.storageError = "Activity could not be saved. No history was deleted. " + error.localizedDescription
                self.queuedOpens.removeAll()
            }
        }
    }
    func refresh() {
        if let demoStore {
            do { snapshot = try demoStore.snapshot(query, now: clock.stamp().at); changed?() } catch { storageError = error.localizedDescription }
            return
        }
        guard ready, !stopped else { return }
        refreshRequested = true
        // A busy collector must not postpone rendering indefinitely. Coalesce
        // updates behind one scheduled/in-flight read, then catch up again.
        guard refreshJob == nil, !refreshInFlight else { return }
        let job = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.refreshJob = nil; self.refreshRequested = false; self.refreshInFlight = true
            let query = self.query
            let now = self.clock.stamp().at
            let pinnedIDs = self.selectedIDs.isEmpty ? [] : self.snapshot.notices.map(\.id)
            self.worker.run({ store in
                var value = try store.snapshot(query, now: now)
                if !pinnedIDs.isEmpty && !query.isTaskView && query.section != .history {
                    let matching = Set(value.matchingIDs)
                    let pinned = try store.selectedNotices(pinnedIDs).filter { matching.contains($0.id) }.map { row in
                        row.contextualized(in: value.taskCatalog)
                    }
                    let current = Dictionary(uniqueKeysWithValues: pinned.map { ($0.id, $0) })
                    var stable = pinnedIDs.compactMap { current[$0] }
                    let known = Set(stable.map(\.id))
                    stable += value.notices.filter { !known.contains($0.id) }.prefix(max(0, query.limit - stable.count))
                    value.notices = stable
                }
                return value
            }) { [weak self] result in
                guard let self, !self.stopped else { return }
                self.refreshInFlight = false
                guard self.query == query else { self.refresh(); return }
                switch result {
                case .success(let value):
                    if !self.selectedIDs.isEmpty && !query.isTaskView && query.section != .history {
                        let matching = Set(value.matchingIDs)
                        self.selectedIDs.formIntersection(matching)
                    }
                    self.snapshot = value; self.changed?(); self.writeStatus()
                case .failure(let error): self.storageError = error.localizedDescription
                }
                if self.refreshRequested { self.refresh() }
            }
        }
        refreshJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: job)
    }
    func setSection(_ section: InboxSection) {
        var next = query; next.section = section; next.limit = 100; next.task = nil
        next.attention = .attention; next.seen = .all; next.showNotifications = false
        historyTaskTitle = nil; query = next
    }
    func selectProject(_ key: String?) { query.project = key; query.task = nil; historyTaskTitle = nil; query.limit = 100 }
    func showHistory(_ task: TaskIdentity) {
        historyTaskTitle = task.title
        query = InboxQuery(section: .history, task: task.key)
    }
    func showAllHistory() { historyTaskTitle = nil; query.task = nil; query.limit = 100 }
    func markDone(_ item: StoredNotice, done: Bool) {
        perform(done ? .done : .reopen, ids: [item.id])
    }
    func selectAllNotices() { selectedIDs = Set(snapshot.matchingIDs) }
    func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }
    func perform(_ action: NoticeAction, ids: Set<String>? = nil) {
        let targets = Array(ids ?? selectedIDs), stamp = clock.stamp()
        guard !targets.isEmpty, !batchBusy, storageError.isEmpty else { return }
        batchBusy = true
        // Use an explicit completion for failures too; no optimistic state changes.
        let job: (InboxStore) throws -> NoticeUndo = { try $0.applyBatch(targets, action: action, at: stamp) }
        let done: @MainActor (Result<NoticeUndo, Error>) -> Void = { [weak self] result in
            guard let self else { return }; self.batchBusy = false
            switch result {
            case .success(let undo):
                self.lastUndo = undo.entries.isEmpty ? self.lastUndo : undo
                self.actionMessage = "\(undo.entries.count) notification\(undo.entries.count == 1 ? "" : "s") updated"
                self.selectedIDs.subtract(targets); self.refresh()
            case .failure(let error): self.storageError = error.localizedDescription
            }
        }
        if let demoStore { done(Result { try job(demoStore) }) } else { worker.run(job, completion: done) }
    }
    func undoLastAction() {
        guard let undo = lastUndo, !batchBusy else { return }
        let stamp = clock.stamp(); lastUndo = nil
        submit({ try $0.undoBatch(undo, at: stamp) }) { [weak self] count in
            self?.actionMessage = "Undid \(count) changes" + (count < undo.entries.count ? " · newer changes kept" : "")
        }
    }
    func copySelection(links: Bool, ids: Set<String>? = nil) {
        let targets = Array(ids ?? selectedIDs).sorted()
        submit({ try $0.selectedNotices(targets) }) { rows in
            let strings = rows.compactMap { links ? $0.notice.url?.absoluteString : $0.task.displayTitle + "\n" + $0.notice.body }
            var seen = Set<String>()
            let text = strings.filter { !links || seen.insert($0).inserted }.joined(separator: links ? "\n" : "\n\n")
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
    }
    func showNotifications(_ task: TaskIdentity) {
        historyTaskTitle = task.displayTitle; query = InboxQuery(section: .all, task: task.key)
    }
    func isOpening(_ url: URL?) -> Bool { url.map { queuedOpens.contains($0) || opener.opening.contains($0) } ?? false }
    func open(_ item: StoredNotice) { openTask(item.task, noticeID: item.id, isTest: item.notice.kind == "test") }
    func open(_ activity: Activity) { openTask(activity.task, noticeID: activity.noticeID) }
    func open(_ task: TaskIdentity) { openTask(task, noticeID: nil) }
    func openNotice(id: String) {
        submit({ try $0.notice(id) }) { [weak self] row in
            if let row { self?.open(row) }
        }
    }
    private func openTask(_ identity: TaskIdentity, noticeID: String?, isTest: Bool = false) {
        guard ready, storageError.isEmpty else { return }
        let stamp = clock.stamp()
        guard let launch = TaskLaunch(thread: identity.thread, host: identity.host) else {
            let attempt = UUID().uuidString
            submit({ store in
                try store.record(kind: "open_clicked", noticeID: noticeID, task: identity, detail: "Requested opening.", at: stamp, attemptID: attempt)
                try store.record(kind: "open_failed", noticeID: noticeID, task: identity, detail: "This entry has no valid task link.", at: stamp, attemptID: attempt)
            })
            opener.error = "This entry has no valid task link. Its attention state is unchanged."
            return
        }
        let alreadyOpening = isOpening(launch.url)
        let attempt = openAttempts[launch.url] ?? UUID().uuidString
        openAttempts[launch.url] = attempt
        if !alreadyOpening { queuedOpens.insert(launch.url) }
        submit({ try $0.record(kind: "open_clicked", noticeID: noticeID, task: identity,
                              detail: alreadyOpening ? "Clicked again while this task was already opening; no second request was sent." : "You clicked to open this task from Codex Inbox.", at: stamp, attemptID: attempt) }) { [weak self] _ in
            guard let self, !alreadyOpening else { return }
            self.queuedOpens.remove(launch.url)
            self.opener.open(launch, onResult: { [weak self] result in
                guard let self else { return }
                if self.openAttempts[launch.url] == attempt { self.openAttempts.removeValue(forKey: launch.url) }
                let time = self.clock.stamp()
                let kind: String, detail: String
                switch result {
                case .success: kind = "open_accepted"; detail = "macOS accepted the task link. Opening does not mark this notification done; actual task visibility is not verified."
                case .failure(let error): kind = "open_failed"; detail = error.message
                }
                self.submit({ try $0.record(kind: kind, noticeID: noticeID, task: identity, detail: detail, at: time, attemptID: attempt) })
            }, onAccepted: {})
        }
    }

    func start() {
        guard !demo, !stopped, !requestedStart else { return }
        requestedStart = true; requestNotifications(); clockCheck.start()
        if activityRefreshTimer == nil {
            activityRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        if ready { launchCollector() }
    }
    private func launchCollector() {
        guard !stopped, process == nil, storageError.isEmpty else { return }
        guard let script = Bundle.main.url(forResource: "collector", withExtension: "py") else { warning = "Collector is missing from the app."; return }
        let child = Process(), output = Pipe(), parent = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", script.path, "--since", String(since), "--inbox-db", databaseURL.path, "--parent-lifetime"]
        child.standardInput = parent; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.process = nil; self.pipe = nil; try? self.lifetime?.fileHandleForWriting.close(); self.lifetime = nil; self.connected = false
                guard !self.stopped else { return }
                self.submit({ try $0.invalidateRuntime() })
                self.warning = "Reconnecting to the local collector…"
                let job = DispatchWorkItem { [weak self] in self?.launchCollector() }
                self.retry = job; DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: job)
            }
        }
        do {
            try child.run(); process = child; pipe = output; lifetime = parent
            try parent.fileHandleForReading.close(); try output.fileHandleForWriting.close()
            reader.start(output.fileHandleForReading, consume: { [weak self] line, done in
                Task { @MainActor in
                    guard let self else { done(); return }
                    self.receiveLine(line, completion: done)
                }
            }, failure: { [weak self] message in
                Task { @MainActor in self?.sourceError = message; self?.safeToAcknowledgeSource = false }
            })
        }
        catch { warning = "Could not start the local collector: \(error.localizedDescription)" }
    }
    // Fixture/manual injection path. Production uses CollectorPipeReader above.
    func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            receiveLine(line, completion: {})
        }
    }
    func receiveLine(_ line: Data, completion: @escaping () -> Void) {
        guard !stopped else { completion(); return }
        guard line.count <= CollectorPipeReader.recordLimit,
              let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            sourceError = "An unreadable update was received. History checkpoints are paused so a restart can recover it."
            safeToAcknowledgeSource = false; completion(); return
        }
        let stamp = clock.stamp()
        // Completion is called only after the serial store operation commits.
        func save<T>(_ job: @escaping (InboxStore) throws -> T, after: @escaping (T) -> Void = { _ in }) {
            worker.run(job) { [weak self] result in
                defer { completion() }
                guard let self else { return }
                switch result {
                case .success(let value): self.refresh(); after(value)
                case .failure(let error):
                    self.storageError = "Activity could not be saved. No history was deleted. " + error.localizedDescription
                    self.safeToAcknowledgeSource = false
                }
            }
        }
        do {
            switch message["type"] as? String {
            case "status":
                lastCollectorContactAt = stamp.at
                connected = message["connected"] as? Bool ?? false; history = message["history"] as? Bool ?? false
                tasks = message["tasks"] as? Int ?? 0; liveTasks = message["liveTasks"] as? Int ?? 0
                warning = message["warning"] as? String ?? ""; writeStatus()
                if !connected { save({ try $0.invalidateRuntime() }) } else { completion() }
            case "runtime":
                let value = try decode(RuntimeObservation.self, from: message["runtime"])
                save({ try $0.observeRuntime(value, at: stamp) })
            case "outcome":
                if let id = message["id"] as? String, let status = message["terminalStatus"] as? String {
                    save({ try $0.enrichOutcome(id, status: status, at: stamp) })
                } else { throw StoreError.database("Turn outcome identity is incomplete.") }
            case "relation":
                let value = try decode(TaskRelation.self, from: message["relation"])
                save({ try $0.observeRelation(value, at: stamp) })
            case "relationship_cursor":
                if safeToAcknowledgeSource, let thread = message["thread"] as? String, let ordinal = message["ordinal"] as? NSNumber {
                    save({ try $0.setMetadata("relationships:v2:" + thread, ordinal.stringValue) })
                } else { completion() }
            case "event":
                let event = try decode(Notice.self, from: message["event"])
                let announce = message["announce"] as? Bool == true
                save({ store -> Bool in
                    let fresh = try store.ingest(event, at: stamp)
                    return try fresh && announce && event.historical != true && store.notice(event.id)?.needsAttention == true
                }, after: { [weak self] fresh in if fresh { self?.alert(event) } })
            case "reply":
                let reply = try decode(Reply.self, from: message["reply"])
                save({ try $0.ingestReply(reply, at: stamp) })
            case "tasks":
                let tasks = try decode([TaskIdentity].self, from: message["tasks"])
                save({ try $0.updateTasks(tasks, at: stamp) })
            case "task_title":
                guard let thread = message["thread"] as? String, let host = message["host"] as? String, let title = message["title"] as? String else { throw StoreError.database("Task title is incomplete.") }
                save({ try $0.updateTitle(thread: thread, host: host, title: title, at: stamp) })
            case "requests":
                let announce = message["announce"] as? Bool == true
                let requests = try decode([RequestObservation].self, from: message["requests"])
                guard let thread = message["thread"] as? String, let host = message["host"] as? String else { throw StoreError.database("Request scope is incomplete.") }
                save({ try $0.ingestRequests(requests, thread: thread, host: host, at: stamp) }, after: { [weak self] notices in
                    if announce { for notice in notices { self?.alert(notice) } }
                })
            case "cursor":
                if safeToAcknowledgeSource, let thread = message["thread"] as? String, let ordinal = message["ordinal"] as? NSNumber {
                    save({ try $0.setMetadata("cursor:" + thread, ordinal.stringValue) })
                } else { completion() }
            default: completion()
            }
        } catch {
            sourceError = "A Codex update could not be read. History checkpoints are paused: \(error.localizedDescription)"
            safeToAcknowledgeSource = false; completion()
        }
    }
    private func decode<T: Decodable>(_ type: T.Type, from value: Any?) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value ?? NSNull()))
    }
    func retryBanner(_ item: StoredNotice) { alert(item.notice, retry: true) }
    private func alert(_ event: Notice, retry: Bool = false) {
        guard !demo, alertsEnabled, bannerInFlight.insert(event.id).inserted else { return }
        if !retry && sound && lastSound.duration(to: .now) > .milliseconds(1500) { soundPlayer(alertSound.rawValue); lastSound = .now }
        let attempt = UUID().uuidString, stamp = clock.stamp()
        bannerAttempts[event.id] = attempt
        worker.run({ try $0.beginBanner(event.id, attemptID: attempt, at: stamp) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.storageError = error.localizedDescription; self.bannerInFlight.remove(event.id)
            case .success:
                self.refresh()
                self.bannerScheduler(event, attempt) { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        let time = self.clock.stamp()
                        self.worker.run({ try $0.finishBanner(event.id, attemptID: attempt, error: error, at: time) }) { [weak self] result in
                            guard let self else { return }
                            guard self.bannerAttempts[event.id] == attempt else { return }
                            self.bannerAttempts.removeValue(forKey: event.id)
                            self.bannerInFlight.remove(event.id)
                            if case .failure(let error) = result { self.storageError = error.localizedDescription }
                            self.refresh()
                        }
                    }
                }
            }
        }
    }
    func previewSound() {
        guard !demo, sound else { return }
        soundPlayer(alertSound.rawValue)
    }
    func test() {
        let stamp = clock.stamp()
        let event = Notice(id: "test-" + UUID().uuidString, thread: "", host: "local", kind: "test", title: "Codex Inbox", body: "Local sound and countdown test. This demo timer does not belong to a Codex task. Mark this entry done when finished.", created: stamp.deviceAt, resolved: false, historical: false, deadline: stamp.deviceAt + 30, estimated: false, timeSource: "observed")
        submit({ try $0.ingest(event, at: stamp) }) { [weak self] fresh in if fresh { self?.alert(event) } }
    }
    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { [weak self] granted, _ in
            Task { @MainActor in self?.notificationPermission = granted ? "" : "Banners are off. The inbox and independent sound still work." }
        }
    }
    private func writeStatus() {
        guard !demo else { return }
        let data: [String: Any] = ["connected": connected, "history": history, "tasks": tasks, "liveTasks": liveTasks,
                                   "working": snapshot.working, "waiting": snapshot.waiting, "unconfirmed": snapshot.unconfirmed,
                                   "warning": !storageError.isEmpty ? storageError : !sourceError.isEmpty ? sourceError : warning, "pending": pendingCount,
                                   "notices": snapshot.total, "activities": snapshot.activityCount,
                                   "clock": clockCheck.status, "at": Date().timeIntervalSince1970]
        if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) {
            try? bytes.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("status.json").path)
        }
    }
    func stop() {
        stopped = true; refreshJob?.cancel(); retry?.cancel(); clockCheck.stop()
        activityRefreshTimer?.invalidate(); activityRefreshTimer = nil
        try? lifetime?.fileHandleForWriting.close(); lifetime = nil
        if process?.isRunning == true { process?.terminate() }
        if !demo { worker.flush(lastRun: Date().timeIntervalSince1970) }
    }

    func disconnectDemo() {
        guard let demoStore else { return }
        try? demoStore.invalidateRuntime(); connected = false
        warning = "Connection lost. Active tasks await fresh confirmation."; refresh()
    }
    func prepareCardDemo(_ state: String) throws {
        guard let demoStore else { return }
        switch state {
        case "empty": _ = try demoStore.applyBatch(try demoStore.matchingNoticeIDs(InboxQuery()), action: .done, at: clock.stamp()); refresh()
        case "loading": ready = false; connected = false; lastCollectorContactAt = nil; snapshot = InboxSnapshot()
        case "stale": lastCollectorContactAt = clock.stamp().at - 600; try demoStore.invalidateRuntime(); refresh()
        case "error": storageError = "History could not be read. Existing records are preserved; open Inbox for details."
        case "permission": notificationPermission = "Banners are off. Your inbox and independent sound still work."
        case "long":
            var values = snapshot.recentActionable.map(\.task)
            for index in values.indices { values[index].title = "Review a very long task title with several projects and pending decisions that should remain available in the main window" }
            try demoStore.updateTasks(values, at: clock.stamp()); refresh()
        default: break
        }
    }
    private func makeDemo() throws {
        let store = try InboxStore(path: ":memory:"); demoStore = store
        let now = clock.stamp()
        let tasks = [TaskIdentity(thread: "archive", title: "Design the archive browser", projectID: "library", projectName: "Archive Library"),
                     TaskIdentity(thread: "website", title: "Update the website", projectID: "studio", projectName: "Studio Website"),
                     TaskIdentity(thread: "notifications", title: "Review notification behavior", projectID: "inbox", projectName: "Codex Inbox")]
        try store.updateTasks(tasks, at: now)
        let bodies = ["Should search include archived documents, or just the current collection?", "Codex needs permission to run the release checks.", "The review is complete. All checks passed and the findings are ready."]
        var earlier = now; earlier.at -= 3600; earlier.deviceAt = earlier.at
        let finished = Notice(id: "sample-done", thread: "archive", host: "local", kind: "completion", title: tasks[0].title, body: "The import preview is ready to review.", created: earlier.at, resolved: false, historical: false, timeSource: "codex")
        try store.ingest(finished, at: earlier)
        earlier.at += 120; earlier.deviceAt = earlier.at
        try store.setDone(finished.id, done: true, at: earlier)
        for index in 0..<3 {
            var stamp = now; stamp.at -= Double(3 - index) * 400; stamp.deviceAt = stamp.at
            let item = Notice(id: "sample-\(index)", thread: tasks[index].thread, host: "local", kind: ["question", "approval", "completion"][index], title: tasks[index].title, body: bodies[index], created: stamp.at, resolved: false, historical: false, deadline: index == 0 ? now.deviceAt + 24 : nil, estimated: index == 0 ? true : nil, sourceOrdinal: Int64(index), timeSource: "codex")
            try store.ingest(item, at: stamp)
            if index == 1 {
                var opened = now; opened.at -= 720; opened.deviceAt = opened.at
                try store.record(kind: "open_clicked", noticeID: "sample-0", task: tasks[0], detail: "You clicked to open this task from Codex Inbox.", at: opened)
                try store.record(kind: "open_accepted", noticeID: "sample-0", task: tasks[0], detail: "macOS accepted the task link. Opening does not mark this notification done.", at: opened)
            }
        }
        let dot = TaskIdentity(thread: "dot-demo", host: "durable", title: "Dot", origin: "dot", originator: "orbit_cca_desktop", threadSource: "aeon")
        let child = TaskIdentity(thread: "research-demo", title: "Compare notification patterns", projectID: "inbox", projectName: "Codex Inbox", threadSource: "agent_created_thread")
        let agent = TaskIdentity(thread: "agent-demo", title: "Review keyboard navigation", projectID: "inbox", projectName: "Codex Inbox", origin: "subagent", threadSource: "subagent", agentNickname: "Ada", agentRole: "reviewer")
        let offline = TaskIdentity(thread: "offline-demo", title: "Check the archive import", projectID: "library", projectName: "Archive Library")
        try store.updateTasks([dot, child, agent, offline], at: now)
        for (task, status, source) in [(dot, "idle", "live"), (child, "working", "live"), (agent, "working", "live"), (offline, "working", "history"), (tasks[0], "waiting_user", "live"), (tasks[1], "waiting_user", "live"), (tasks[2], "finished", "live")] {
            try store.observeRuntime(RuntimeObservation(thread: task.thread, host: task.host, status: status, turn: "current", source: source), at: now)
        }
        try store.observeRelation(TaskRelation(thread: child.thread, host: child.host, parentThread: dot.thread, parentHost: dot.host, kind: "created", sourceID: "demo-created"), at: now)
        try store.observeRelation(TaskRelation(thread: agent.thread, host: agent.host, parentThread: child.thread, parentHost: child.host, kind: "subagent", sourceID: "demo-spawn"), at: now)
        try store.observeRelation(TaskRelation(thread: child.thread, host: child.host, parentThread: tasks[2].thread, parentHost: "local", kind: "delegated", sourceID: "demo-delegation"), at: now)
        var interruption = now; interruption.at -= 180; interruption.deviceAt = interruption.at
        try store.ingest(Notice(id: "dot-interrupted", thread: dot.thread, host: dot.host, kind: "error", title: dot.title, body: "This turn was interrupted. The source did not supply a reason.", created: interruption.at, resolved: false, timeSource: "codex", turn: "earlier", terminalStatus: "interrupted"), at: interruption)
        try store.ingest(Notice(id: "agent-question", thread: agent.thread, host: agent.host, kind: "question", title: agent.title, body: "Should keyboard focus return to the next notification after marking this one done?", created: now.at - 80, resolved: false, timeSource: "codex"), at: now)
        try store.ingest(Notice(id: "tool-input", thread: child.thread, host: child.host, kind: "input", title: child.title, body: "Choose which connected calendar to use for this task.", created: now.at - 90, resolved: false, timeSource: "codex"), at: now)
        try store.ingest(Notice(id: "source-failed", thread: offline.thread, host: offline.host, kind: "error", title: offline.title, body: "The import check could not read its source. Review the task for the recorded error.", created: now.at - 100, resolved: false, timeSource: "codex", terminalStatus: "failed"), at: now)
        try store.record(kind: "open_clicked", noticeID: "dot-interrupted", task: dot, detail: "Opening requested.", at: now, attemptID: "demo-open")
        try store.record(kind: "open_failed", noticeID: "dot-interrupted", task: dot, detail: "The opening request timed out. No display was confirmed.", at: now, attemptID: "demo-open")
        if CommandLine.arguments.contains("--agent-family") {
            let owner = TaskIdentity(thread: "family-owner", title: "Synthesize MCP audit findings", projectID: "family", projectName: "custom-mcp-tools")
            let agents = [TaskIdentity(thread: "family-kierkegaard", title: "Kierkegaard", projectID: "family", projectName: "custom-mcp-tools", origin: "subagent"), TaskIdentity(thread: "family-popper", title: "Popper", projectID: "family", projectName: "custom-mcp-tools", origin: "subagent")]
            try store.updateTasks([owner] + agents, at: now)
            for agent in agents { try store.observeRelation(TaskRelation(thread: agent.thread, host: agent.host, parentThread: owner.thread, parentHost: owner.host, kind: "subagent", sourceID: "native-parent"), at: now) }
            for (task, bodies) in [(owner, ["The observer-pause fix passed its targeted check.", "The browser capture fix is ready for review."]), (agents[1], ["Review findings are ready.", "The second review preserved the same checks."]), (agents[0], ["The latest review is finalized.", "The load diagnosis is ready.", "The observer-pause review is complete."])] {
                for (index, body) in bodies.enumerated() {
                    try store.ingest(Notice(id: "\(task.thread)-\(index)", thread: task.thread, host: task.host, kind: "completion", title: task.title, body: body, created: now.at - Double(index + 1) * 300, resolved: false, timeSource: "codex", turn: "family-turn-\(index)", terminalStatus: "completed"), at: now)
                }
            }
        }
        if CommandLine.arguments.contains("--many-projects") {
            for index in 0..<8 {
                let task = TaskIdentity(thread: "project-demo-\(index)", title: "Review running project \(index + 1)", projectID: index == 7 ? nil : "project-demo-\(index)", projectName: index == 7 ? nil : "Project \(index + 1)")
                try store.updateTasks([task], at: now)
                try store.observeRuntime(RuntimeObservation(thread: task.thread, host: task.host, status: "working", turn: "current", source: "live"), at: now)
            }
        }
        if CommandLine.arguments.contains("--large") {
            for index in 0..<700 {
                let notice = Notice(id: "large-\(index)", thread: child.thread, host: child.host, kind: "completion", title: child.title, body: "Review item \(index + 1). This synthetic entry exercises a large inbox without touching your data.", created: now.at - Double(index), resolved: false, timeSource: "codex", terminalStatus: "completed")
                try store.ingest(notice, at: now)
            }
        }
    }
}
