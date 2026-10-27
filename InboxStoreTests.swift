import Foundation

@main struct InboxStoreTests {
    static func stamp(_ at: Double = 2000) -> EventTime {
        EventTime(at: at, deviceAt: at, elapsed: at, session: "test", quality: "Fixture time")
    }
    static func notice(_ id: String, task: String = "task", host: String = "local", ordinal: Int64? = 10, created: Double = 1000, kind: String = "question") -> Notice {
        Notice(id: id, thread: task, host: host, kind: kind, title: "A task", body: "Question: \(id)", created: created, resolved: false, historical: false, sourceOrdinal: ordinal, timeSource: "codex")
    }
    static func reply(_ id: String, task: String = "task", host: String = "local", ordinal: Int64? = 11, created: Double? = 1001, live: Bool = true) -> Reply {
        Reply(id: id, thread: task, host: host, body: "A message", created: created, sourceOrdinal: ordinal, live: live)
    }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ explanation: String) throws {
        if try !condition() { throw StoreError.database("Test failed: " + explanation) }
    }
    @MainActor static func waitFor(_ explanation: String, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw StoreError.database("Timed out: " + explanation)
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--live-clock") {
            let name = "local.codex.inbox.clock-test." + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let clock = TimelineClock(), check = ClockCheck(clock: clock, defaults: defaults)
            await check.check(force: true)
            print(check.status)
            print("Timestamp provenance: " + clock.stamp().quality)
            if !check.warning.isEmpty { print(check.warning) }
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-inbox-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("activity.sqlite").path
        var store: InboxStore? = try InboxStore(path: path)
        let task = TaskIdentity(thread: "task", title: "Original title", projectID: "p1", projectName: "Project One")
        try store!.updateTasks([task], at: stamp())
        try store!.ingest(notice("question"), at: stamp())
        try store!.record(kind: "open_clicked", noticeID: "question", task: task, detail: "Click", at: stamp(2001))
        try store!.record(kind: "open_clicked", noticeID: "question", task: task, detail: "Second click", at: stamp(2001))
        try store!.record(kind: "open_failed", noticeID: "question", task: task, detail: "Failure", at: stamp(2002))
        try expect(store!.notice("question")!.needsAttention, "Clicking or an opening failure must not mark done")
        try store!.record(kind: "open_accepted", noticeID: "question", task: task, detail: "Accepted", at: stamp(2003))
        try expect(store!.notice("question")!.needsAttention, "Successful handoff must still need attention")
        try expect(store!.notice("question")!.clickedAt == 2001 && store!.notice("question")!.openedAt == 2003, "Click and handoff have distinct timestamps")
        let count = try store!.snapshot(InboxQuery(section: .history)).activityCount
        try store!.ingest(notice("question"), at: stamp())
        try expect(store!.snapshot(InboxQuery(section: .history)).activityCount == count, "Replaying a notification must not add history")
        try store!.ingestReply(reply("old", ordinal: 9, created: 999999), at: stamp())
        try expect(store!.notice("question")!.needsAttention, "An older message with a misleading clock must not clear attention")
        try store!.ingestReply(reply("remote", host: "remote"), at: stamp())
        try expect(store!.notice("question")!.needsAttention, "A reply on another host must not clear attention")
        try store!.ingest(notice("completion", ordinal: 8, kind: "completion"), at: stamp())
        try store!.ingest(notice("future", ordinal: 20), at: stamp())
        try store!.ingestReply(reply("answer", created: -500), at: stamp())
        try expect(!store!.notice("question")!.needsAttention && !store!.notice("completion")!.needsAttention, "Any later message handles preceding alerts even if the clock moves backward")
        try expect(store!.notice("future")!.needsAttention, "A message before a later alert must not handle that alert")
        try expect(store!.notice("question")!.doneReason == "reply", "A later message is not labelled as an exact answer")
        try store!.setDone("question", done: false, at: stamp(2004))
        try store!.ingestReply(reply("answer", created: 1234), at: stamp())
        try store!.ingest(notice("question"), at: stamp())
        try expect(store!.notice("question")!.needsAttention, "Backfill cannot undo a manual reopening")
        try store!.ingestReply(reply("late-backfill", ordinal: 12, created: 1002, live: false), at: stamp(2010))
        try expect(store!.notice("question")!.needsAttention, "A newly discovered old message must not undo a reopening")
        try store!.ingestReply(reply("new-answer", ordinal: 12, created: 2005), at: stamp(2005))
        try expect(!store!.notice("question")!.needsAttention, "A genuinely new reply can handle a reopened alert")
        var ended = notice("request", ordinal: 50)
        try store!.ingest(ended, at: stamp())
        ended.resolved = true; ended.resolution = "request_ended"
        try store!.ingest(ended, at: stamp())
        try expect(store!.notice("request")!.needsAttention, "A disappeared request is not proof of action")
        ended.resolution = "answered"
        try store!.ingest(ended, at: stamp())
        try expect(store!.notice("request")!.needsAttention, "Unordered resolution text cannot clear attention")
        ended.questionID = "question-request"
        try store!.ingest(ended, at: stamp())
        var orderedAnswer = reply("ordered-answer", ordinal: 51, created: 2001)
        orderedAnswer.answeredQuestionIDs = ["question-request"]
        try store!.ingestReply(orderedAnswer, at: stamp(2002))
        try expect(!store!.notice("request")!.needsAttention, "An ordered matched answer can clear attention")
        try store!.setDone("future", done: false, at: stamp(2005))
        try store!.setDone("future", done: true, at: stamp(2006))
        try store!.ingest(notice("future"), at: stamp())
        try expect(store!.notice("future")!.doneReason == "manual", "Source refresh must preserve manual Done")

        // A source record arriving after its reply still reconciles correctly.
        try store!.ingestReply(reply("out-of-order", task: "late", ordinal: 12, live: false), at: stamp())
        try store!.ingest(notice("late", task: "late"), at: stamp())
        try expect(!store!.notice("late")!.needsAttention, "Arrival order must not determine source reply order")
        try store!.ingest(notice("clock-unknown", task: "unknown", ordinal: nil), at: stamp())
        try store!.ingestReply(reply("unknown-past", task: "unknown", ordinal: nil, created: nil, live: false), at: stamp())
        try expect(store!.notice("clock-unknown")!.needsAttention, "An undated historical message is not evidence of a later reply")
        var observedRequest = notice("observed-request", task: "offline", ordinal: nil, kind: "approval")
        observedRequest.timeSource = "observed"
        try store!.ingest(observedRequest, at: stamp())
        try store!.ingestReply(reply("offline-reply", task: "offline", ordinal: nil, created: 1005, live: false), at: stamp())
        try expect(!store!.notice("observed-request")!.needsAttention, "History-only replies can settle requests captured before disconnection")

        // Metadata follows real task IDs. Activity snapshots keep previous names.
        let moved = TaskIdentity(thread: "task", title: "Renamed task", projectID: "p2", projectName: "Project Two")
        try store!.updateTasks([moved], at: stamp(10))
        let history = try store!.snapshot(InboxQuery(section: .history, task: task.key))
        try expect(history.activities.first!.kind == "task_updated", "Sequence preserves capture order despite clock rollback")
        try expect(history.activities.contains { $0.kind == "open_clicked" && $0.task.title == "Original title" && $0.task.projectID == "p1" }, "Old click identity must survive renaming and moving projects")
        let project = try store!.snapshot(InboxQuery(section: .all, project: moved.projectKey))
        try expect(project.notices.count == 4 && project.notices.allSatisfy { $0.task.title == "Renamed task" }, "Project view and combined labels use current task membership")
        try expect(store!.snapshot(InboxQuery(section: .all, search: "Project Two")).matchingCount == 4, "Project names are searchable")
        store = nil
        store = try InboxStore(path: path)
        try expect(store!.notice("question")!.openedAt == 2003 && store!.notice("future")!.doneReason == "manual", "History and attention states survive process restart")

        let legacyFile = root.appendingPathComponent("inbox.json")
        let legacy = LegacyArchive(notices: [notice("legacy-open-question"), notice("legacy-done", kind: "completion"), notice("legacy-unread")], seen: ["legacy-open-question", "legacy-done"], lastRun: 1800)
        let original = try JSONEncoder().encode(legacy); try original.write(to: legacyFile)
        let migrated = try InboxStore(path: root.appendingPathComponent("migrated.sqlite").path)
        try migrated.migrateLegacy(files: [legacyFile], at: stamp())
        try migrated.migrateLegacy(files: [legacyFile], at: stamp())
        try expect(migrated.snapshot(InboxQuery(section: .all)).total == 3, "Migration is idempotent")
        try expect(Data(contentsOf: legacyFile) == original, "Migration leaves original file untouched")
        try expect(migrated.notice("legacy-open-question")!.needsAttention && migrated.notice("legacy-open-question")!.openedAt == nil, "Previously Seen unresolved questions resurface without invented click time")
        try expect(migrated.notice("legacy-done")!.doneReason == "legacy_seen", "Legacy Seen is not relabelled as proof of a reply")
        let broken = root.appendingPathComponent("broken.json"); try Data("not-json".utf8).write(to: broken)
        let badStore = try InboxStore(path: ":memory:")
        do { try badStore.migrateLegacy(files: [legacyFile, broken], at: stamp()); throw StoreError.database("Bad migration unexpectedly succeeded") }
        catch is DecodingError { }
        try expect(badStore.snapshot(InboxQuery()).total == 0 && badStore.metadata("legacy_imported") == nil, "Bad migration must not partially import or set its marker")

        // More than the former 500-entry limit, with a small displayed page.
        let longHistory = try InboxStore(path: ":memory:")
        for i in 0..<1205 {
            let item = notice("retained-\(i)")
            try longHistory.ingest(item, at: stamp(Double(i)))
            try longHistory.setDone(item.id, done: true, at: stamp(Double(i)))
        }
        let page = try longHistory.snapshot(InboxQuery(section: .done))
        try expect(page.total == 1205 && page.notices.count == 100 && page.matchingCount == 1205, "Paging must not delete stored history")
        try expect(longHistory.snapshot(InboxQuery(section: .history, limit: 3000)).activities.count == 2410, "Every arrival and manual action remains in chronological history")

        var wall = 1000.0, elapsed = 0.0
        let clock = TimelineClock(wall: { wall }, elapsed: { elapsed })
        elapsed = 10; wall = -500
        try expect(clock.stamp().at == 1010 && clock.stamp().quality.contains("changed"), "Clock edits must not reverse elapsed event time")
        try expect(!clock.accept(date: 5000, age: 3600, roundTrip: 1), "Cached server time must be rejected")
        try expect(!clock.accept(date: 5000, age: nil, roundTrip: 8), "Slow clock response must be rejected")
        try expect(clock.accept(date: 5000, age: 0, roundTrip: 0.2), "Fresh network reference must be accepted")
        elapsed += 20
        try expect(abs(clock.stamp().at - 5020.1) < 0.001, "Network anchor uses continuous elapsed time")
        elapsed += 90000
        try expect(clock.stamp().quality.contains("Estimated"), "Stale clock references must be labelled estimates")

        // Exercise the actual controller button path, with both OS opening and
        // notifications disabled. The click must be durable before handoff.
        let controllerRoot = root.appendingPathComponent("controller")
        var calls = 0, callback: TaskOpener.Completion?
        let opening = TaskOpener(launcher: { _, done in calls += 1; callback = done })
        let inbox = Inbox(directory: controllerRoot, opener: opening, alertsEnabled: false)
        try await waitFor("controller store") { inbox.ready }
        let raw = try JSONSerialization.data(withJSONObject: ["type": "event", "event": JSONSerialization.jsonObject(with: JSONEncoder().encode(notice("click-test")))])
        inbox.receive(raw + Data([10]))
        try await waitFor("notification row") { inbox.snapshot.notices.count == 1 }
        inbox.open(inbox.snapshot.notices[0])
        try await waitFor("injected launcher") { calls == 1 }
        let observer = try InboxStore(path: inbox.databaseURL.path)
        try expect(observer.snapshot(InboxQuery(section: .history)).activities.contains { $0.kind == "open_clicked" }, "Click must be durably saved before OS launch")
        callback?(.success(()))
        try await waitFor("opening acceptance") { inbox.snapshot.notices.first?.openedAt != nil }
        try expect(inbox.pendingCount == 1, "Opening through the controller must not clear the badge")
        inbox.markDone(inbox.snapshot.notices[0], done: true)
        try await waitFor("manual Done") { inbox.pendingCount == 0 }
        inbox.receive(Data("{bad-json}\n{\"type\":\"cursor\",\"thread\":\"task\",\"ordinal\":99}\n{\"type\":\"status\",\"warning\":\"\"}\n".utf8))
        try expect(!inbox.sourceError.isEmpty, "Collector status cannot erase a malformed-update warning")
        inbox.stop()
        try expect(observer.metadata("cursor:task") == nil, "Malformed source updates must not advance durable checkpoints")
        print("Activity checks passed: durable clicks, reply ordering, manual Done/reopen, migration, project identity, history retention/paging, clock changes, and the real controller flow. No applications or notifications were opened.")
    }
}
