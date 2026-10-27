import Foundation
import SQLite3
import Darwin

@main struct InboxRepairTests {
    static func stamp(_ n: Double = 100) -> EventTime { EventTime(at: n, deviceAt: n, elapsed: n, session: "fixture", quality: "Fixture") }
    static func notice(_ id: String = "n", task: String = "t", ordinal: Int64? = 10) -> Notice {
        Notice(id: id, thread: task, host: "local", kind: "question", title: "Title", body: "Question", created: 50, resolved: false, historical: false, sourceOrdinal: ordinal, timeSource: "codex", questionID: "q")
    }
    static func reply(_ id: String, created: Double? = 60, ordinal: Int64? = 11, fresh: Bool = false, aliases: [String] = [], answers: [String] = []) -> Reply {
        Reply(id: id, thread: "t", host: "local", body: "Answer", created: created, sourceOrdinal: ordinal, live: fresh, provenance: fresh ? "new_action" : "discovery", aliases: aliases, answeredQuestionIDs: answers)
    }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw StoreError.database(message) } }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw StoreError.database("Async fixture timed out")
    }
    @MainActor static func main() async throws {
        if let position = CommandLine.arguments.firstIndex(of: "--stream-memory") {
            try await streamMemory(Int(CommandLine.arguments[position + 1])!); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-repair-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // CN-015: SQLite byte counts, including NUL at either end and reopen.
        let db = root.appendingPathComponent("bytes.sqlite").path
        var store: InboxStore? = try InboxStore(path: db)
        let texts = ["", "\0leading", "trailing\0", "a\0🙂é尾\0b"]
        for (i, text) in texts.enumerated() {
            try store!.setMetadata("bytes\(i)", text)
            try store!.record(kind: "fixture", noticeID: nil, task: TaskIdentity(thread: "t", title: text), detail: text, at: stamp(Double(i)))
        }
        var n = notice(); n.body = texts.last!; try store!.ingest(n, at: stamp())
        n.body = "replaced\0尾"; try store!.ingest(n, at: stamp())
        store = nil; store = try InboxStore(path: db)
        for (i, text) in texts.enumerated() { try expect(store!.metadata("bytes\(i)") == text, "CN-015 metadata round-trip") }
        try expect(store!.notice("n")!.notice.body == n.body, "CN-015 payload replacement")
        var raw: OpaquePointer?; sqlite3_open_v2(db, &raw, SQLITE_OPEN_READONLY, nil); defer { sqlite3_close(raw) }
        var stmt: OpaquePointer?; sqlite3_prepare_v2(raw, "SELECT hex(value) FROM meta WHERE key='bytes3'", -1, &stmt, nil); defer { sqlite3_finalize(stmt) }
        try expect(sqlite3_step(stmt) == SQLITE_ROW, "byte query")
        let hex = String(cString: sqlite3_column_text(stmt, 0))
        try expect(hex == texts.last!.utf8.map { String(format: "%02X", $0) }.joined(), "CN-015 exact stored bytes")
        // CN-003: opaque snapshots, reconnect/restart reuse one occurrence.
        let requests = [RequestObservation(identity: "host/task/method/transport/0", opaque: true, kind: "approval", body: "Approve?")]
        let first = try store!.ingestRequests(requests, thread: "r", host: "remote", at: stamp())
        try expect(first.count == 1, "CN-003 first occurrence")
        try store!.setDone(first[0].id, done: true, at: stamp(101))
        for _ in 0..<100 { try expect(store!.ingestRequests(requests, thread: "r", host: "remote", at: stamp(102)).isEmpty, "CN-003 snapshot duplicate") }
        store = nil; store = try InboxStore(path: db)
        try expect(store!.ingestRequests(requests, thread: "r", host: "remote", at: stamp(103)).isEmpty, "CN-003 restart duplicate")
        _ = try store!.ingestRequests([], thread: "r", host: "remote", at: stamp(104))
        let next = try store!.ingestRequests(requests, thread: "r", host: "remote", at: stamp(105))
        try expect(next.count == 1 && next[0].id != first[0].id, "CN-003 authoritative absence creates next occurrence")
        var distinct = requests; distinct[0].identity += "/new-turn"; distinct[0].opaque = false
        try expect(store!.ingestRequests(distinct, thread: "r", host: "remote", at: stamp(106)).count == 1, "CN-003 new operation with reused request number")
        try expect(store!.notice(first[0].id)!.doneReason == "manual", "CN-003 preserve manual decisions")
        // CN-004/005/006: ordinary and explicit answers share one manual guard.
        for explicit in [false, true] {
            for order in [false, true] {
                let s = try InboxStore(path: ":memory:")
                try s.ingest(notice(), at: stamp())
                let early = reply(order ? "steer" : "canonical", aliases: [order ? "item:steer" : "server:u"], answers: explicit ? ["q"] : [])
                try s.ingestReply(early, at: stamp(101))
                try s.setDone("n", done: false, at: stamp(110))
                try s.ingestReply(reply("old-discovery", created: 65, ordinal: 12, fresh: true, answers: explicit ? ["q"] : []), at: stamp(111))
                try expect(s.notice("n")!.needsAttention, "CN-004/005 old newly discovered evidence cannot undo Reopen")
                let lateAlias = reply(order ? "canonical" : "steer", created: 60, fresh: true, aliases: ["item:steer", "server:u"], answers: explicit ? ["q"] : [])
                try s.ingestReply(lateAlias, at: stamp(112))
                try expect(s.notice("n")!.needsAttention, "CN-006 alias cannot become a new action")
                try expect(s.snapshot(InboxQuery(section: .history)).activities.filter { $0.kind == "message_sent" }.count == 2, "CN-006 no alias capture duplication")
                try s.ingestReply(reply("new", created: 120, ordinal: 14, fresh: true, answers: explicit ? ["q"] : []), at: stamp(121))
                try expect(!s.notice("n")!.needsAttention && s.notice("n")!.doneReason == (explicit ? "answer" : "reply"), "CN-004/005 genuinely later action")
            }
        }
        let outOfOrder = try InboxStore(path: ":memory:")
        try outOfOrder.ingestReply(reply("before-question", answers: ["q"]), at: stamp())
        try outOfOrder.ingest(notice(), at: stamp(110))
        try expect(outOfOrder.notice("n")!.doneReason == "answer", "CN-005 answer-before-question joins durably")
        try outOfOrder.setDone("n", done: false, at: stamp(120))
        try outOfOrder.ingestReply(reply("unknown", created: nil, ordinal: nil, answers: ["q"]), at: stamp(130))
        try expect(outOfOrder.notice("n")!.needsAttention, "CN-005 unknown order stays pending")
        // CN-013/014/019: captured project membership, historic catalog and title-only update.
        let projects = try InboxStore(path: ":memory:")
        for knowledge in ["none", "unknown", "assigned"] {
            let tid = "p-" + knowledge
            let t = TaskIdentity(thread: tid, title: "Then", projectID: knowledge == "assigned" ? "A" : nil, projectName: knowledge == "assigned" ? "Alpha" : nil, projectKnowledge: knowledge)
            try projects.updateTasks([t], at: stamp())
            try projects.ingest(notice(tid, task: tid), at: stamp())
            try projects.updateTasks([TaskIdentity(thread: tid, title: "Now", projectID: "B", projectName: "Beta", projectKnowledge: "assigned")], at: stamp(120))
        }
        let historic = try projects.snapshot(InboxQuery(section: .history))
        try expect(Set(historic.projects.map(\.id)) == ["", "unknown", "local\u{1f}A", "local\u{1f}B"], "CN-014 old project remains selectable")
        try expect(projects.snapshot(InboxQuery(section: .history, project: "")).activities.allSatisfy { $0.task.projectID == nil && $0.task.projectKnowledge == "none" }, "CN-013 known projectless remains projectless")
        try projects.updateTitle(thread: "p-assigned", host: "local", title: "Newest", at: stamp(130))
        try expect(projects.task("local\u{1f}p-assigned")!.projectID == "B", "CN-019 title-only preserves membership")
        // CN-020: each imported activity uses its own original notice title.
        var old = notice("old"), recent = notice("recent"); old.title = "First"; recent.title = "Second"; recent.created = 51
        let legacy = root.appendingPathComponent("legacy.json")
        let original = try JSONEncoder().encode(LegacyArchive(notices: [old, recent], seen: [], lastRun: 1)); try original.write(to: legacy)
        let migration = try InboxStore(path: ":memory:")
        try migration.migrateLegacy(files: [legacy], at: stamp()); try migration.migrateLegacy(files: [legacy], at: stamp())
        let imported = try migration.snapshot(InboxQuery(section: .history)).activities
        try expect(imported.first { $0.noticeID == "old" }!.task.title == "First" && imported.first { $0.noticeID == "recent" }!.task.title == "Second", "CN-020 notice-specific titles")
        try expect(Data(contentsOf: legacy) == original, "CN-020 original file preserved")
        // CN-012: persistent results, unknown interruption and stale callback protection.
        try store!.beginBanner("n", attemptID: "a", at: stamp())
        try store!.finishBanner("n", attemptID: "a", error: "Permission denied", at: stamp())
        store = nil; store = try InboxStore(path: db)
        try expect(store!.bannerState("n")!.state == "failed", "CN-012 failure survives restart")
        try store!.beginBanner("n", attemptID: "b", at: stamp())
        try store!.finishBanner("n", attemptID: "a", error: nil, at: stamp())
        try expect(store!.bannerState("n")!.state == "unknown", "CN-012 stale callback ignored")
        try store!.finishBanner("n", attemptID: "b", error: nil, at: stamp())
        try expect(store!.bannerState("n")!.state == "accepted", "CN-012 scheduling acceptance")
        var callbacks: [(String?) -> Void] = [], scheduled = 0
        let inbox = Inbox(directory: root.appendingPathComponent("controller"), bannerScheduler: { _, _, done in scheduled += 1; callbacks.append(done) }, soundPlayer: { _ in })
        try await wait { inbox.ready }
        let event = try JSONEncoder().encode(notice("controller"))
        let line = Data("{\"type\":\"event\",\"announce\":true,\"event\":".utf8) + event + Data("}".utf8)
        inbox.receiveLine(line, completion: {})
        try await wait { scheduled == 1 }
        callbacks[0]("Injected scheduling failure")
        try await wait { inbox.snapshot.notices.first?.banner?.state == "failed" }
        let item = inbox.snapshot.notices[0]
        inbox.retryBanner(item); inbox.retryBanner(item)
        try await wait { scheduled == 2 }
        callbacks[0](nil)
        try await Task.sleep(for: .milliseconds(60))
        try expect(inbox.bannerInFlight.contains(item.id), "CN-012 stale callback cannot finish the newer retry")
        callbacks[1](nil)
        try await wait { inbox.snapshot.notices.first?.banner?.state == "accepted" }
        try expect(inbox.pendingCount == 1, "CN-012 retries do not answer")
        inbox.receiveLine(line, completion: {})
        try await Task.sleep(for: .milliseconds(180))
        try expect(scheduled == 2, "CN-012 source replay cannot retry")
        // Real background reader with slow commits: no second envelope delivered early.
        let pipe = Pipe(), reader = CollectorPipeReader()
        let lock = NSLock(); var received = 0, waiting = 0, peak = 0
        let done = DispatchSemaphore(value: 0)
        reader.start(pipe.fileHandleForReading, consume: { _, commit in
            lock.lock(); received += 1; waiting += 1; peak = max(peak, waiting); let n = received; lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) {
                lock.lock(); waiting -= 1; lock.unlock(); commit(); if n == 100 { done.signal() }
            }
        }, failure: { _ in done.signal() })
        DispatchQueue.global().async {
            for _ in 0..<100 { try? pipe.fileHandleForWriting.write(contentsOf: Data("{}\n".utf8)) }
            try? pipe.fileHandleForWriting.close()
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { done.wait(); continuation.resume() }
        }
        try expect(peak == 1 && received == 100, "CN-002 pipe backpressure bounds queued envelopes")
        inbox.stop()
        try await integratedFlow(root)
        print("Repair checks passed: CN-002/003/004/005/006/012/013/014/015/019/020. No real banners or applications opened.")
    }
    @MainActor static func integratedFlow(_ root: URL) async throws {
        let inbox = Inbox(directory: root.appendingPathComponent("integrated"), alertsEnabled: false)
        try await wait { inbox.ready }
        let child = Process(), pipe = Pipe(), life = Pipe(), reader = CollectorPipeReader()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "test_flow_fixture.py", root.appendingPathComponent("source").path]
        child.standardOutput = pipe; child.standardInput = life
        try child.run(); try pipe.fileHandleForWriting.close(); try life.fileHandleForReading.close()
        reader.start(pipe.fileHandleForReading, consume: { line, done in
            Task { @MainActor in inbox.receiveLine(line, completion: done) }
        }, failure: { message in print("Integration reader: " + message) })
        let observer = try InboxStore(path: inbox.databaseURL.path)
        try await wait { (try? observer.metadata("cursor:flow-check")) == "3000" }
        try expect(observer.notice("local:task:turn:turn")!.notice.body == "Final from snapshot", "CN-002 full collector-to-store completion")
        try expect(observer.snapshot(InboxQuery(section: .all)).total == 2, "CN-003 repeated request snapshots make one stored occurrence")
        try expect(observer.snapshot(InboxQuery(section: .history, limit: 4000)).activities.filter { $0.kind == "message_sent" }.count == 129, "CN-002 pages and CN-006 alias share durable reply identity")
        try expect(observer.metadata("cursor:task") == "3000", "CN-002 both streams commit before coverage")
        try life.fileHandleForWriting.close()
        try await wait { !child.isRunning }
        inbox.stop()
    }
    @MainActor static func streamMemory(_ count: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-memory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = Inbox(directory: root, alertsEnabled: false)
        try await wait { inbox.ready }
        let pipe = Pipe(), reader = CollectorPipeReader()
        reader.start(pipe.fileHandleForReading, consume: { line, done in
            Task { @MainActor in inbox.receiveLine(line, completion: done) }
        }, failure: { print($0) })
        DispatchQueue.global().async {
            for index in 0..<count {
                let value = Reply(id: "r" + String(index), thread: "memory", host: "local", body: String(repeating: "x", count: 4096), created: 1, sourceOrdinal: Int64(index), live: false)
                let line = Data("{\"type\":\"reply\",\"reply\":".utf8) + (try! JSONEncoder().encode(value)) + Data("}\n".utf8)
                try? pipe.fileHandleForWriting.write(contentsOf: line)
            }
            try? pipe.fileHandleForWriting.write(contentsOf: Data("{\"type\":\"cursor\",\"thread\":\"memory\",\"ordinal\":\(count)}\n".utf8))
            try? pipe.fileHandleForWriting.close()
        }
        let observer = try InboxStore(path: inbox.databaseURL.path)
        // This checks bounded recovery memory, not disk throughput. Each reply
        // commits with synchronous=FULL; measured 10,000-record runs take about
        // 25 seconds with large variations between batches. Allow slow progress
        // without hiding a stalled stream or an unbounded wait.
        let started = ContinuousClock.now
        let deadline = started + .seconds(120)
        var progressDeadline = started + .seconds(30), nextProgressCheck = started
        var committed = 0
        while try observer.metadata("cursor:memory") != String(count) {
            let now = ContinuousClock.now
            if now >= nextProgressCheck {
                let received = try observer.count("SELECT COUNT(*) FROM replies")
                if received > committed { committed = received; progressDeadline = now + .seconds(30) }
                nextProgressCheck = now + .seconds(1)
            }
            try expect(inbox.storageError.isEmpty && inbox.sourceError.isEmpty, "Streaming recovery failed: \(inbox.storageError) \(inbox.sourceError)")
            try expect(now < progressDeadline && now < deadline, "Streaming recovery timed out after \(started.duration(to: now)); committed \(committed)/\(count) replies")
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(observer.count("SELECT COUNT(*) FROM replies") == count, "Streaming recovery reply count")
        try expect(observer.count("SELECT COUNT(*) FROM activity WHERE kind='message_sent'") == count, "Streaming recovery journal count")
        print("STREAM_TIME \(count) \(started.duration(to: .now))")
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("STREAM_RSS \(count) \(usage.ru_maxrss)")
        inbox.stop()
    }

}
