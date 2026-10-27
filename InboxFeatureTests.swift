import AppKit
import SwiftUI
import Foundation
import SQLite3

@main struct InboxFeatureTests {
    static func time(_ n: Double = 1000) -> EventTime { EventTime(at: n, deviceAt: n, elapsed: n, session: "fixture", quality: "Fixture") }
    static func notice(_ id: String, thread: String = "task", host: String = "local", kind: String = "question", status: String? = nil) -> Notice {
        Notice(id: id, thread: thread, host: host, kind: kind, title: "Task " + thread, body: "Notification " + id, created: 10, resolved: false, sourceOrdinal: 10, timeSource: "codex", turn: "turn", terminalStatus: status)
    }
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw StoreError.database("Feature test: " + message) }
    }
    static func sql(_ path: String, _ query: String) throws {
        var db: OpaquePointer?; sqlite3_open(path, &db); defer { sqlite3_close(db) }
        if sqlite3_exec(db, query, nil, nil, nil) != SQLITE_OK { throw StoreError.database(String(cString: sqlite3_errmsg(db))) }
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        throw StoreError.database("Feature test timed out")
    }
    static func stateChecks(_ root: URL) throws {
        let path = root.appendingPathComponent("state.sqlite").path
        var store: InboxStore? = try InboxStore(path: path)
        let identity = TaskIdentity(thread: "task", title: "Task")
        try store!.ingest(notice("a"), at: time())
        try store!.ingest(notice("b"), at: time())
        try store!.record(kind: "open_clicked", noticeID: "a", task: identity, detail: "Clicked", at: time(1001), attemptID: "old")
        try store!.record(kind: "open_failed", noticeID: "a", task: identity, detail: "Failed", at: time(1002), attemptID: "old")
        try check(store!.notice("a")!.seen && store!.notice("a")!.needsAttention, "failed opening marks Seen only")
        let unseen = try store!.applyBatch(["a"], action: .unseen, at: time(1003))
        try store!.ingest(notice("a"), at: time(1004))
        try check(!store!.notice("a")!.seen, "replay cannot undo Mark unseen")
        try store!.setDone("a", done: true, at: time(1005))
        try check(!store!.notice("a")!.seen && !store!.notice("a")!.needsAttention, "Done does not invent Seen")
        try check(store!.undoBatch(unseen, at: time(1006)) == 1, "seen undo remains independent of Done")
        let reopen = try store!.applyBatch(["a"], action: .reopen, at: time(1007))
        try store!.ingestReply(Reply(id: "new", thread: "task", host: "local", body: "Reply", created: 1008, sourceOrdinal: 11, live: true, provenance: "new_action"), at: time(1008))
        try check(store!.undoBatch(reopen, at: time(1009)) == 0, "Undo preserves a later reply")
        try store!.setDone("a", done: false, at: time(1010))
        let done = try store!.applyBatch(["a"], action: .done, at: time(1011))
        try store!.ingestReply(Reply(id: "after-done", thread: "task", host: "local", body: "New reply", created: 1012, sourceOrdinal: 12, live: true, provenance: "new_action"), at: time(1012))
        try check(store!.undoBatch(done, at: time(1013)) == 0, "Undo Done cannot reopen over a newer reply even when already handled")
        try store!.setDone("a", done: false, at: time(1014))
        try store!.ingestReply(Reply(id: "old-recovery", thread: "task", host: "local", body: "Old", created: 500, sourceOrdinal: 13, live: false, provenance: "discovery"), at: time(1015))
        try check(store!.notice("a")!.needsAttention, "historical replies cannot undo manual Reopen")
        _ = try store!.applyBatch(["a"], action: .unseen, at: time(1016))
        try sql(path, "CREATE TRIGGER fail_batch BEFORE UPDATE OF seen ON notices WHEN NEW.id='b' AND NEW.seen=1 BEGIN SELECT RAISE(ABORT,'injected'); END")
        let before = try store!.snapshot(InboxQuery(section: .history)).activityCount
        do { _ = try store!.applyBatch(["a", "b"], action: .seen, at: time(1017)); throw StoreError.database("Batch unexpectedly succeeded") }
        catch { try check(String(describing: error).contains("injected"), "test reached injected batch failure") }
        try check(!store!.notice("a")!.seen && !store!.notice("b")!.seen, "batch failure rolls back every projection")
        try check(store!.snapshot(InboxQuery(section: .history)).activityCount == before, "batch failure rolls back journal too")
        try sql(path, "DROP TRIGGER fail_batch")
        _ = try store!.applyBatch(["a", "b"], action: .seen, at: time(1018))
        store = nil; store = try InboxStore(path: path)
        try check(store!.notice("a")!.seen && store!.notice("b")!.seen && store!.notice("a")!.needsAttention, "states survive restart")
        try store!.record(kind: "open_clicked", noticeID: "a", task: identity, detail: "New attempt", at: time(1020), attemptID: "new")
        try store!.record(kind: "open_accepted", noticeID: "a", task: identity, detail: "Late old result", at: time(1021), attemptID: "old")
        try check(store!.snapshot(InboxQuery(section: .recent)).taskRows[0].openResult == "unknown", "stale result cannot complete a newer opening")
        try store!.record(kind: "open_failed", noticeID: "a", task: identity, detail: "New failure", at: time(1022), attemptID: "new")
        let recent = try store!.snapshot(InboxQuery(section: .recent))
        try check(recent.matchingCount == 1 && recent.taskRows[0].openResult == "failed" && recent.taskRows[0].lastClickedAt == 1020, "Recent deduplicates tasks and keeps latest failure")
        let other = TaskIdentity(thread: "task", host: "remote", title: "Different host")
        try store!.record(kind: "open_clicked", noticeID: nil, task: other, detail: "Remote", at: time(1023))
        try check(store!.snapshot(InboxQuery(section: .recent)).matchingCount == 2, "Recent isolates hosts")
    }
    static func viewChecks() throws {
        let store = try InboxStore(path: ":memory:")
        let observed = time(Date().timeIntervalSince1970)
        let dot = TaskIdentity(thread: "root", host: "durable", title: "Codex task", origin: "dot")
        let child = TaskIdentity(thread: "child", title: "Child", projectID: "p", projectName: "Project")
        let agent = TaskIdentity(thread: "agent", title: "Agent", projectID: "p", projectName: "Project", origin: "subagent")
        let peer = TaskIdentity(thread: "peer", title: "Peer")
        try store.updateTasks([dot, child, agent, peer], at: time())
        try store.observeRelation(TaskRelation(thread: "child", host: "local", parentThread: "root", parentHost: "durable", kind: "created", sourceID: "creation"), at: time())
        try store.observeRelation(TaskRelation(thread: "agent", host: "local", parentThread: "child", parentHost: "local", kind: "subagent", sourceID: "spawn"), at: time())
        try store.observeRelation(TaskRelation(thread: "peer", host: "local", parentThread: "root", parentHost: "durable", kind: "delegated", sourceID: "message"), at: time())
        let relationshipCount = try store.snapshot(InboxQuery(section: .history)).activityCount
        for _ in 0..<5 {
            try store.observeRelation(TaskRelation(thread: "peer", host: "local", parentThread: "root", parentHost: "durable", kind: "delegated", sourceID: "message"), at: time(1001))
        }
        try check(store.snapshot(InboxQuery(section: .history)).activityCount == relationshipCount, "relationship replay does not duplicate journal events")
        try check(store.taskCatalog()[peer.key]!.isDot == false, "delegation is not creation attribution")
        try check(store.taskCatalog()[agent.key]!.isDot, "Dot ancestry propagates to nested subagents")
        try check(store.taskCatalog()[dot.key]!.task.displayTitle == "Dot", "known Dot has a useful fallback title")
        try store.updateTasks([TaskIdentity(thread: "root", host: "durable", title: "Renamed")], at: time())
        try check(store.taskCatalog()[dot.key]!.isDot, "sparse metadata preserves known origin")
        for (id, kind, status) in [("q", "question", ""), ("approval", "approval", ""), ("input", "input", ""), ("finished", "completion", "completed"), ("interrupted", "error", "interrupted"), ("failed", "error", "failed")] {
            try store.ingest(notice(id, thread: "agent", kind: kind, status: status.isEmpty ? nil : status), at: time())
        }
        for section in [InboxSection.questions, .approvals, .input, .finished, .interrupted, .failed] {
            let result = try store.snapshot(InboxQuery(section: section, project: "local\u{1f}p"))
            try check(result.matchingCount == 1 && result.sectionCounts[section] == 1, "type views and counts agree")
        }
        try check(store.snapshot(InboxQuery(section: .dot, showNotifications: true)).matchingCount == 6, "Dot notification filter includes evidenced descendants")
        _ = try store.applyBatch(["q"], action: .seen, at: time())
        try check(store.snapshot(InboxQuery(section: .questions, seen: .unseen)).matchingCount == 0, "Unseen is shared across views")
        try store.setDone("q", done: true, at: time())
        try check(store.snapshot(InboxQuery(section: .questions, attention: .done)).matchingCount == 1, "Done filter works in Questions")
        for i in 0..<220 { try store.ingest(notice("page-\(i)", thread: "child", kind: "completion"), at: time()) }
        let page = try store.snapshot(InboxQuery(section: .finished, limit: 25))
        try check(page.notices.count == 25 && page.matchingIDs.count == 221, "all matching IDs are available without loading payload pages")
        let captured = page.matchingIDs
        try store.ingest(notice("late-arrival", thread: "child", kind: "completion"), at: time())
        _ = try store.applyBatch(captured, action: .done, at: time())
        try check(store.notice("late-arrival")!.needsAttention, "Select All has a fixed target set")
        let live = RuntimeObservation(thread: "child", host: "local", status: "working", turn: "new", sourceOrdinal: 20, source: "live")
        try store.observeRuntime(live, at: observed)
        try check(store.taskCatalog(now: observed.at + 91)[child.key]!.isUnconfirmed, "silence expires confirmation without completing work")
        try store.observeRuntime(live, at: time(observed.at + 60))
        try check(!store.taskCatalog(now: observed.at + 100)[child.key]!.isUnconfirmed, "fresh identical live observation renews confirmation")
        try store.observeRuntime(RuntimeObservation(thread: "child", host: "local", status: "finished", turn: "old", sourceOrdinal: 10, source: "history"), at: time())
        try check(store.taskCatalog()[child.key]!.status == "Working", "older history cannot replace newer live work")
        try store.observeRuntime(RuntimeObservation(thread: "child", host: "local", status: "finished", turn: "new", sourceOrdinal: 30, source: "history"), at: time())
        try store.observeRuntime(RuntimeObservation(thread: "child", host: "local", status: "working", turn: "new", source: "live"), at: time())
        try check(store.taskCatalog()[child.key]!.status == "Finished", "stale running snapshot cannot resurrect the terminal turn")
        try store.observeRuntime(RuntimeObservation(thread: "agent", host: "local", status: "working", turn: "a", source: "live"), at: observed)
        let running = try store.snapshot(InboxQuery(section: .running))
        try check(running.matchingCount == 1 && running.working == 1 && running.taskRows.count == 3, "inactive ancestors are context, excluded from counts")
        try store.invalidateRuntime()
        try check(store.snapshot(InboxQuery(section: .running)).unconfirmed == 1, "disconnect retains activity as unconfirmed")
        try check(store.snapshot(InboxQuery(section: .running)).matchingCount == 0, "unconfirmed work is not counted as running")
        let uncertain = try store.snapshot(InboxQuery(section: .unconfirmed))
        try check(uncertain.matchingCount == 1 && uncertain.taskRows.count == 3 && uncertain.sectionCounts[.unconfirmed] == 1, "unconfirmed tasks have their own view with parent context")
        try store.observeRuntime(RuntimeObservation(thread: "agent", host: "local", status: "working", turn: "a", source: "live"), at: observed)
        try check(store.snapshot(InboxQuery(section: .running)).working == 1, "fresh reconnect observation restores confirmation")
        for index in 0..<35 { try store.observeRuntime(RuntimeObservation(thread: "active\(index)", host: "local", status: "working", turn: "a", source: "live"), at: observed) }
        try check(store.snapshot(InboxQuery(section: .running)).matchingCount == 36, "running view has no twelve-task cap")
        try store.updateTasks([TaskIdentity(thread: "same", host: "a", title: "A"), TaskIdentity(thread: "same", host: "b", title: "B")], at: time())
        try store.observeRelation(TaskRelation(thread: "orphan", host: "local", parentThread: "same", kind: "created", sourceID: "ambiguous"), at: time())
        try check(store.taskCatalog()["local\u{1f}orphan"]!.parentKey == nil, "unknown host never picks an arbitrary parent")
        try store.observeRelation(TaskRelation(thread: "root", host: "durable", parentThread: "agent", parentHost: "local", kind: "created", sourceID: "cycle"), at: time())
        _ = try store.snapshot(InboxQuery(section: .running)) // Cycles must terminate.
    }
    static func runningProjectChecks() throws {
        let store = try InboxStore(path: ":memory:")
        let stamp = time()
        let tasks = [
            TaskIdentity(thread: "a", title: "Alpha", projectID: "p", projectName: "Project"),
            TaskIdentity(thread: "b", title: "Beta", projectID: "p", projectName: "Project"),
            TaskIdentity(thread: "a", host: "remote", title: "Remote", projectID: "p", projectName: "Project"),
            TaskIdentity(thread: "free", title: "Unassigned", projectKnowledge: "none"),
            TaskIdentity(thread: "free", host: "remote", title: "Remote unassigned", projectKnowledge: "none"),
            TaskIdentity(thread: "parent", title: "Idle parent", projectID: "other", projectName: "Other"),
            TaskIdentity(thread: "finished", title: "Finished", projectID: "other", projectName: "Other")
        ]
        try store.updateTasks(tasks, at: stamp)
        for (index, task) in tasks.enumerated() {
            let status = ["working", "waiting_user", "waiting_agents", "working", "working", "idle", "finished"][index]
            try store.observeRuntime(RuntimeObservation(thread: task.thread, host: task.host, status: status, turn: "t", sourceOrdinal: 1, source: "live"), at: stamp)
        }
        try store.observeRelation(TaskRelation(thread: "a", host: "local", parentThread: "parent", parentHost: "local", kind: "created", sourceID: "running-parent"), at: stamp)
        let filtered = try store.snapshot(InboxQuery(section: .finished, project: "missing", search: "no match", limit: 1), now: stamp.at)
        let groups = filtered.runningProjects
        try check(filtered.matchingCount == 0 && groups.count == 3, "running cards remain global across project, search, section and page filters")
        try check(groups.reduce(0) { $0 + $1.tasks.count } == 5, "cards include every confirmed working and waiting chat, without inactive parent context")
        try check(groups.first { $0.id == "local\u{1f}p" }?.tasks.map(\.task.title) == ["Alpha", "Beta"], "same-project chats share a card with stable title ordering")
        try check(groups.filter { $0.name == "Project" }.count == 2, "project identity includes host even when names and IDs match")
        try check(groups.last?.name == "No project" && groups.last?.tasks.count == 2, "unassigned chats share the No project card without merging thread identities")
        try check(try store.snapshot(InboxQuery(section: .history), now: stamp.at).runningProjects.map(\.id) == groups.map(\.id), "history retains running cards")
        try store.observeRuntime(RuntimeObservation(thread: "a", host: "local", status: "finished", turn: "t", sourceOrdinal: 2, source: "live"), at: stamp)
        try check(store.snapshot(InboxQuery(), now: stamp.at).runningProjects.flatMap(\.tasks).count == 4, "completion removes a chat from the cards")
        try check(store.snapshot(InboxQuery(), now: stamp.at + 91).runningProjects.isEmpty, "expired runtime confirmation does not appear as currently running")
        try store.invalidateRuntime()
        try check(store.snapshot(InboxQuery(), now: stamp.at).runningProjects.isEmpty, "disconnect clears confirmed cards while preserving stored activity")
        try store.observeRuntime(RuntimeObservation(thread: "free", host: "local", status: "working", turn: "t", sourceOrdinal: 1, source: "live"), at: stamp)
        try check(store.snapshot(InboxQuery(), now: stamp.at).runningProjects.first?.tasks.count == 1, "fresh live confirmation restores a card")
    }

    static func migrationChecks(_ root: URL) throws {
        let path = root.appendingPathComponent("legacy.sqlite").path
        try sql(path, """
        CREATE TABLE tasks(key TEXT PRIMARY KEY,host TEXT,thread TEXT,title TEXT,project_key TEXT,project_name TEXT,payload TEXT);
        CREATE TABLE notices(id TEXT PRIMARY KEY,task_key TEXT,payload TEXT,first_seq INTEGER,attention INTEGER,done_reason TEXT,clicked_at REAL,opened_at REAL,legacy_seen INTEGER DEFAULT 0,reopened_seq INTEGER DEFAULT 0,reopened_at REAL);
        CREATE TABLE activity(seq INTEGER PRIMARY KEY AUTOINCREMENT,dedup TEXT UNIQUE,notice_id TEXT,task_key TEXT,task_json TEXT,project_key TEXT,kind TEXT,detail TEXT,time_json TEXT,source_at REAL);
        """)
        var store: InboxStore? = try InboxStore(path: path)
        try store!.ingest(notice("legacy"), at: time())
        try sql(path, "UPDATE notices SET legacy_seen=1,seen=0 WHERE id='legacy'; DELETE FROM meta WHERE key='selection_v1';")
        store = nil; store = try InboxStore(path: path)
        let row = try store!.notice("legacy")!
        try check(row.seen && row.clickedAt == nil && row.openedAt == nil && row.needsAttention, "migration derives Seen without inventing times or Done")
        try check(store!.snapshot(InboxQuery(section: .recent)).matchingCount == 0, "legacy Seen does not invent an opening visit")
    }
    static func groupingChecks() throws {
        let store = try InboxStore(path: ":memory:")
        let parent = TaskIdentity(thread: "parent", host: "durable", title: "Dot", origin: "dot")
        let child = TaskIdentity(thread: "child", title: "Kant", projectID: "p", projectName: "Child project", origin: "subagent")
        let peer = TaskIdentity(thread: "peer", title: "Existing user chat", threadSource: "user")
        let nested = TaskIdentity(thread: "nested", title: "Locke", origin: "subagent")
        try store.updateTasks([parent, child, peer, nested], at: time())
        try store.observeRelation(TaskRelation(thread: child.thread, host: child.host, parentThread: parent.thread, parentHost: parent.host, kind: "subagent", sourceID: "native-parent"), at: time())
        try store.observeRelation(TaskRelation(thread: nested.thread, host: nested.host, parentThread: child.thread, parentHost: child.host, kind: "subagent", sourceID: "spawn:child"), at: time())
        // Reproduce the old collector's false ownership records, including an
        // interaction with somebody else's genuine subagent.
        for target in [peer, child] {
            try store.observeRelation(TaskRelation(thread: target.thread, host: target.host, parentThread: nested.thread, parentHost: nested.host, kind: "subagent", sourceID: "parent:nested"), at: time())
        }
        let catalog = try store.taskCatalog()
        try check(!catalog[peer.key]!.isSubagent && catalog[peer.key]!.parentKey == nil, "old chat interactions do not turn user chats into subagents")
        try check(catalog[child.key]!.parentKey == parent.key && catalog[nested.key]!.isDot, "authoritative ancestry survives old conflicting activity records")
        try check(store.count("SELECT COUNT(*) FROM task_relations WHERE json_extract(payload,'$.sourceID')='parent:nested' AND json_extract(payload,'$.kind')='subagent'") == 2, "original relationship evidence is preserved")
        for (id, task) in [("parent-alert", parent), ("peer-alert", peer), ("child-alert", child), ("nested-alert", nested)] {
            try store.ingest(notice(id, thread: task.thread, host: task.host), at: time())
        }
        let snapshot = try store.snapshot(InboxQuery(section: .questions))
        let grouped = NoticeGrouping.entries(snapshot.notices, catalog: snapshot.taskCatalog)
        try check(grouped.compactMap(\.project).map(\.key) == ["", child.projectKey], "project boxes follow the newest loaded alert and preserve project identity")
        try check(Set(grouped.compactMap(\.group).map(\.key)) == Set([parent.key, child.key, nested.key, peer.key]), "every chat and intermediate parent has an explicit tree header")
        try check(Set(grouped.map(\.id)).count == grouped.count, "context headers in different project boxes have distinct identities")
        try check(grouped.compactMap(\.notice).count == 4 && Set(grouped.compactMap { $0.notice?.id }).count == 4, "group headers never duplicate notifications")
        try check(grouped.filter { $0.notice != nil }.allSatisfy { $0.projectKey == $0.notice!.task.projectKey }, "cross-project ancestry never moves a notification into its parent's project")
        let nestedHeader = grouped.first { $0.group?.key == nested.key }
        try check(nestedHeader?.depth == 2 && nestedHeader?.branches == [false, false] && nestedHeader?.startsChildren == false, "nested-agent branches stop at the chat; own notifications do not start another relationship trunk")
        try check(grouped.first(where: { $0.notice?.id == "nested-alert" })?.depth == 3, "notification leaves sit beneath their chat header")
        try check(grouped.first(where: { $0.notice?.id == "nested-alert" })?.notice?.parentTask?.key == child.key, "direct parent remains available beneath the root group")
        let collapsed = NoticeGrouping.entries(snapshot.notices, catalog: snapshot.taskCatalog, collapsed: [parent.key])
        try check(collapsed.compactMap(\.notice).map(\.id) == ["peer-alert"] && collapsed.filter { $0.group?.key == parent.key }.allSatisfy { !$0.startsChildren }, "collapse hides only that family's loaded notifications and closes its tree branches")
        let childCollapsed = NoticeGrouping.entries(snapshot.notices, catalog: snapshot.taskCatalog, collapsed: [child.key])
        try check(Set(childCollapsed.compactMap(\.notice).map(\.id)) == Set(["parent-alert", "peer-alert"]), "an intermediate chat can collapse its own notifications and descendants")
        let filtered = try store.snapshot(InboxQuery(section: .questions, project: child.projectKey, limit: 1))
        let filteredRows = NoticeGrouping.entries(filtered.notices, catalog: filtered.taskCatalog)
        try check(filtered.matchingCount == 1 && filteredRows.compactMap(\.notice).map(\.id) == ["child-alert"] && filteredRows.first(where: { $0.group != nil })?.group?.key == parent.key, "filtered child pages retain context without importing nonmatching parent alerts")
        try check(filteredRows.first(where: { $0.group?.key == parent.key })?.contextOnly == true, "out-of-project parent headers are explicitly context")
        try store.updateTasks([TaskIdentity(thread: "parent", host: "local", title: "Unrelated same ID")], at: time())
        try check(store.taskCatalog()[child.key]!.parentKey == parent.key, "grouping does not merge parent identities across hosts")
        try store.observeRelation(TaskRelation(thread: parent.thread, host: parent.host, parentThread: nested.thread, parentHost: nested.host, kind: "created", sourceID: "cycle"), at: time())
        let cyclic = try store.snapshot(InboxQuery(section: .questions))
        try check(NoticeGrouping.entries(cyclic.notices, catalog: cyclic.taskCatalog).compactMap(\.notice).count == 4, "cycles cannot hide or duplicate alerts")
        let remote = TaskIdentity(thread: "child", host: "remote", title: "Remote child", projectID: "p", projectName: "Child project")
        try store.updateTasks([remote], at: time())
        try store.ingest(notice("remote-alert", thread: remote.thread, host: remote.host), at: time())
        let remoteSnapshot = try store.snapshot(InboxQuery(section: .questions))
        let remoteRows = NoticeGrouping.entries(remoteSnapshot.notices, catalog: remoteSnapshot.taskCatalog)
        try check(remoteRows.compactMap(\.project).filter { $0.name == "Child project" }.count == 2, "same-name and same-ID projects on different hosts remain separate boxes")
        try check(NoticeGrouping.entries([], catalog: catalog).isEmpty, "empty pages have no synthetic project rows")
        let family = try InboxStore(path: ":memory:")
        let owner = TaskIdentity(thread: "owner", title: "Owner chat", projectID: "family", projectName: "Family")
        let siblings = [TaskIdentity(thread: "kierkegaard", title: "Kierkegaard", projectID: "family", projectName: "Family", origin: "subagent"), TaskIdentity(thread: "popper", title: "Popper", projectID: "family", projectName: "Family", origin: "subagent")]
        try family.updateTasks([owner] + siblings, at: time())
        for child in siblings {
            try family.observeRelation(TaskRelation(thread: child.thread, host: child.host, parentThread: owner.thread, parentHost: owner.host, kind: "subagent", sourceID: "native-parent"), at: time())
        }
        for (task, count) in [(owner, 2), (siblings[0], 3), (siblings[1], 2)] {
            for index in 0..<count { try family.ingest(notice("\(task.thread)-\(index)", thread: task.thread, kind: "completion"), at: time()) }
        }
        let familySnapshot = try family.snapshot(InboxQuery())
        let familyRows = NoticeGrouping.entries(familySnapshot.notices, catalog: familySnapshot.taskCatalog)
        let ownerHeader = familyRows.first { $0.group?.key == owner.key }
        try check(ownerHeader?.ownCount == 2 && ownerHeader?.childSubagentCount == 2 && ownerHeader?.count == 7, "chat headers distinguish their own reports from direct subagents and descendant report totals")
        try check(familyRows.first?.project?.chatCount == 1 && familyRows.first?.project?.subagentCount == 2, "project headers count chats and subagents separately")
        let agentHeaders = familyRows.filter { siblings.map(\.key).contains($0.group?.key ?? "") }
        try check(agentHeaders.count == 2 && agentHeaders.allSatisfy { $0.depth == 1 && !$0.startsChildren }, "multiple reports do not turn sibling subagents into a chain")
        try check(familyRows.filter { $0.notice?.task.key == siblings[1].key }.allSatisfy { $0.branches == [true, false] }, "a passing parent trunk continues toward a sibling without branching to notification cards")
        try check(familyRows.filter { $0.notice != nil }.allSatisfy { $0.boxes.last?.key == $0.notice?.task.key }, "every update is physically contained in its owning chat or subagent card")
        try check(agentHeaders.allSatisfy { $0.boxes.map(\.key) == [owner.key, $0.group!.key] && $0.boxes.last?.isSubagent == true }, "sibling subagent cards sit inside their parent's chat card")
        try check(familyRows.filter { $0.content != nil }.count == 4 && familyRows.contains { $0.content?.title == "SUBAGENTS · 2" }, "chat updates and subagents have distinct named sections")
        try check(Set(familyRows.map(\.id)).count == familyRows.count, "section and card-end rows have stable unique identities")
        var openCards: [String] = []
        for entry in familyRows {
            if let chat = entry.group { openCards.append(chat.key) }
            if let end = entry.conversationEnd { try check(openCards.popLast() == end, "chat containers close in nested order") }
        }
        try check(openCards.isEmpty, "every chat container closes")
        let collapsedFamily = NoticeGrouping.entries(familySnapshot.notices, catalog: familySnapshot.taskCatalog, collapsed: [owner.key])
        try check(collapsedFamily.compactMap(\.notice).isEmpty && collapsedFamily.compactMap(\.conversationEnd) == [owner.key], "collapsed chats retain a closed card without importing descendants")
        let sampleReply = notice("meaning", kind: "completion")
        try check(sampleReply.inboxHeading == "Final reply · Turn completed", "completed-turn cards describe the reply and the turn rather than the whole chat")
        var legacyReply = sampleReply; legacyReply.turn = nil
        try check(legacyReply.inboxHeading == "Completion update", "legacy completions do not invent a known turn identity")
        var chronology = familySnapshot.notices
        let times: [String: Double] = ["owner-0": 400, "owner-1": 100, "kierkegaard-0": 300, "kierkegaard-1": 200, "kierkegaard-2": 500, "popper-0": 600, "popper-1": 99999]
        for index in chronology.indices {
            chronology[index].notice.created = times[chronology[index].id]!
            if chronology[index].id == "popper-1" { chronology[index].notice.timeSource = "unknown" }
        }
        let timeline = NoticeGrouping.entries(chronology, catalog: familySnapshot.taskCatalog, layout: .timeline)
        try check(timeline.compactMap(\.notice).map(\.id) == ["popper-0", "kierkegaard-2", "owner-0", "kierkegaard-0", "kierkegaard-1", "owner-1", "popper-1"], "timeline interleaves parent and sibling reports by source time, with unknown timestamps last")
        try check(timeline.filter { $0.notice?.task.key == owner.key }.allSatisfy { $0.timelineActor == "MAIN CHAT" }, "timeline entries identify the parent chat")
        try check(timeline.filter { $0.notice?.task.key == siblings[0].key }.allSatisfy { $0.timelineActor == "SUBAGENT · Kierkegaard" && $0.actorIsSubagent }, "timeline entries identify the subagent without implying a parent-turn link")
        try check(timeline.compactMap(\.group).map(\.key) == [owner.key] && timeline.filter { $0.notice != nil }.allSatisfy { $0.branches.isEmpty }, "timeline chronology does not masquerade as the ownership tree")
    }

    @MainActor static func refreshChecks(_ root: URL) async throws {
        let inbox = Inbox(directory: root.appendingPathComponent("continuous-refresh"), alertsEnabled: false)
        defer { inbox.stop() }
        try await wait { inbox.ready }
        var updatedDuringStream = false
        for index in 0..<70 {
            let raw = try JSONSerialization.data(withJSONObject: ["type": "event", "event": JSONSerialization.jsonObject(with: JSONEncoder().encode(notice("stream-\(index)")))])
            inbox.receive(raw + Data([10]))
            if index == 10 {
                inbox.receive(Data("{\"type\":\"tasks\",\"tasks\":[{\"thread\":\"task\",\"host\":\"local\",\"title\":\"Dot\",\"origin\":\"dot\"}]}\n".utf8))
            }
            if index == 30 { inbox.query.search = "Notification" }
            if index > 35 && inbox.snapshot.matchingCount > 10 && inbox.snapshot.notices.first?.task.displayTitle == "Dot" { updatedDuringStream = true }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        try check(updatedDuringStream, "continuous arrivals must publish updated labels and counts before the stream stops")
        try await wait { inbox.snapshot.matchingCount == 70 }
        inbox.query.search = "no match"
        try await wait { inbox.snapshot.matchingCount == 0 }
    }
    @MainActor static func controllerAndNativeChecks(_ root: URL) async throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        var launches = 0
        let opener = TaskOpener(launcher: { _, result in launches += 1; result(.failure(.timedOut)) })
        let inbox = Inbox(directory: root.appendingPathComponent("controller"), opener: opener, alertsEnabled: false)
        try await wait { inbox.ready }
        for index in 0..<135 {
            let n = notice("native-\(index)")
            let raw = try JSONSerialization.data(withJSONObject: ["type": "event", "event": JSONSerialization.jsonObject(with: JSONEncoder().encode(n))])
            inbox.receive(raw + Data([10]))
        }
        try await wait { inbox.snapshot.matchingCount == 135 }
        let coordinator = NativeNoticeList.Coordinator(inbox)
        let table = NoticeTable(); let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        table.addTableColumn(NSTableColumn(identifier: .init("test"))); table.rowHeight = 94; table.headerView = nil
        table.allowsMultipleSelection = true; table.dataSource = coordinator; table.delegate = coordinator
        coordinator.table = table; scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll // Intentionally never ordered onscreen.
        coordinator.update(inbox, scroll: scroll)
        scroll.layoutSubtreeIfNeeded()
        func nativeRow(_ noticeIndex: Int) -> Int {
            coordinator.entries.firstIndex { $0.notice?.id == inbox.snapshot.notices[noticeIndex].id }!
        }
        func click(_ row: Int, flags: NSEvent.ModifierFlags = []) {
            let point = table.convert(NSPoint(x: 80, y: table.rect(ofRow: nativeRow(row)).midY), to: nil)
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            NSApp.postEvent(up, atStart: true); table.mouseDown(with: down)
            coordinator.update(inbox, scroll: scroll)
        }
        click(1)
        try check(inbox.selectedIDs == [inbox.snapshot.notices[1].id], "plain native click selects one notification")
        click(3, flags: .command)
        try check(table.selectedRowIndexes == IndexSet([nativeRow(1), nativeRow(3)]) && inbox.selectedIDs.count == 2, "native Cmd-click toggles nonadjacent rows")
        click(1, flags: .command)
        try check(table.selectedRowIndexes == IndexSet(integer: nativeRow(3)), "native Cmd-click removes an individual row")
        click(1); click(4, flags: .shift)
        try check(table.selectedRowIndexes == IndexSet(integersIn: nativeRow(1)...nativeRow(4)), "native Shift-click includes both endpoints")
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift, .function, .numericPad], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125)!
        table.keyDown(with: down)
        try check(table.selectedRowIndexes == IndexSet(integersIn: nativeRow(1)...nativeRow(5)), "native Shift-arrow extends selection")
        coordinator.checkbox(inbox.snapshot.notices[2].id, modifiers: [])
        coordinator.checkbox(inbox.snapshot.notices[5].id, modifiers: .shift)
        try check(inbox.selectedIDs == Set(inbox.snapshot.notices[2...5].map(\.id)), "checkbox Shift-range shares the same selection")
        table.selectEveryMatch = { inbox.selectAllNotices() }
        table.clearSelection = { inbox.selectedIDs = [] }
        table.openSelection = { coordinator.openSelected() }
        table.selectAll(nil)
        try check(inbox.selectedIDs.count == 135 && launches == 0, "native Select All includes unloaded pages and never opens")
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        table.keyDown(with: enter)
        try check(launches == 0, "Return never bulk opens selected notifications")
        coordinator.update(inbox, scroll: scroll)
        try check(table.selectedRowIndexes.count == 100, "native checkboxes represent the loaded subset of one selection")
        let selectionBeforeLayout = inbox.selectedIDs
        coordinator.update(inbox, scroll: scroll, layout: .timeline)
        try check(inbox.selectedIDs == selectionBeforeLayout && coordinator.entries.filter { $0.notice != nil }.allSatisfy { $0.timelineActor != nil }, "switching to timeline preserves selected IDs, including unloaded notifications")
        coordinator.update(inbox, scroll: scroll, layout: .byChat)
        try check(inbox.selectedIDs == selectionBeforeLayout && table.selectedRowIndexes.count == 100, "returning to hierarchy restores the same selected notifications")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 220)); scroll.reflectScrolledClipView(scroll.contentView)
        let offset = scroll.contentView.bounds.origin
        coordinator.update(inbox, scroll: scroll)
        try check(scroll.contentView.bounds.origin == offset, "refresh preserves scroll position")
        let first = inbox.snapshot.notices[0]
        coordinator.checkbox(first.id, modifiers: [])
        try check(inbox.selectedIDs.count == 134, "checkbox toggles while preserving unloaded selections")
        _ = coordinator.menu(nativeRow(1))
        try check(inbox.selectedIDs.count == 134, "right click on selected row preserves the whole selection")
        _ = coordinator.menu(nativeRow(0))
        try check(inbox.selectedIDs == [first.id], "right click outside selection targets only that row")
        let observer = try InboxStore(path: inbox.databaseURL.path)
        try check(!observer.notice(first.id)!.seen && launches == 0, "selection and context menu do not mark seen or navigate")
        var mappedTask: TaskIdentity?
        coordinator.showMap = { mappedTask = $0 }
        let groupIndex = coordinator.entries.firstIndex { $0.group != nil }!
        let mapCell = coordinator.tableView(table, viewFor: table.tableColumns[0], row: groupIndex) as! NoticeGroupCell
        let journalBeforeMap = try observer.snapshot(InboxQuery()).activityCount
        mapCell.mapButton.performClick(nil)
        try check(mappedTask?.thread == first.task.thread, "native Map action identifies the owning conversation")
        try check(launches == 0 && !observer.notice(first.id)!.seen && observer.notice(first.id)!.needsAttention && (try observer.snapshot(InboxQuery()).activityCount) == journalBeforeMap, "Map inspects history without opening or changing notification state")
        table.keyDown(with: enter)
        try await wait { launches == 1 && inbox.snapshot.notices.first(where: { $0.id == first.id })?.seen == true }
        try check(observer.notice(first.id)!.needsAttention, "opening through native action preserves attention")
        inbox.selectAllNotices()
        let selected = inbox.selectedIDs
        let new = try JSONSerialization.data(withJSONObject: ["type": "event", "event": JSONSerialization.jsonObject(with: JSONEncoder().encode(notice("incoming")))])
        let stable = inbox.snapshot.notices.map(\.id)
        inbox.receive(new + Data([10]))
        try await wait { inbox.snapshot.matchingCount == 136 }
        try check(inbox.selectedIDs == selected && inbox.snapshot.notices.map(\.id) == stable, "arrival preserves selection and displayed order")
        let retained = stable.last!
        _ = try observer.applyBatch([retained], action: .seen, at: time())
        inbox.refresh()
        try await wait { inbox.snapshot.notices.last?.seen == true }
        try check(inbox.snapshot.notices.last?.id == retained, "retained rows beyond a changed page receive current state")
        inbox.query.limit += 100
        try check(inbox.selectedIDs == selected, "pagination does not clear selection")
        inbox.query.seen = .unseen
        try check(inbox.selectedIDs.isEmpty, "filter change clears selection")
        inbox.query = InboxQuery()
        inbox.receive(Data("{\"type\":\"tasks\",\"tasks\":[{\"thread\":\"parent\",\"host\":\"local\",\"title\":\"Parent chat\"}]}\n".utf8))
        inbox.receive(Data("{\"type\":\"relation\",\"relation\":{\"thread\":\"task\",\"host\":\"local\",\"parentThread\":\"parent\",\"parentHost\":\"local\",\"kind\":\"subagent\",\"sourceID\":\"native-parent\"}}\n".utf8))
        try await wait { inbox.snapshot.notices.first?.parentTask?.thread == "parent" }
        coordinator.update(inbox, scroll: scroll)
        try check(coordinator.entries.first?.project?.name == "No project" && coordinator.entries.first(where: { $0.group != nil })?.group?.thread == "parent", "native list exposes the project and parent headers")
        let allIndexes = IndexSet(coordinator.entries.indices)
        let noticeIndexes = IndexSet(coordinator.entries.indices.filter { coordinator.entries[$0].notice != nil })
        try check(coordinator.tableView(table, selectionIndexesForProposedSelection: allIndexes) == noticeIndexes, "project, chat and footer rows are excluded from range selection")
        click(1); click(3, flags: .shift)
        try check(inbox.selectedIDs.count == 3 && launches == 1, "native selection still works beneath a parent header without opening")
        table.selectAll(nil); coordinator.update(inbox, scroll: scroll)
        let groupedSelection = inbox.selectedIDs
        coordinator.toggleGroup("local\u{1f}parent")
        try check(coordinator.entries.compactMap(\.notice).isEmpty && inbox.selectedIDs == groupedSelection, "collapsing preserves selection including unloaded notifications")
        coordinator.toggleGroup("local\u{1f}parent")
        try check(table.selectedRowIndexes.count == 100 && table.selectedRowIndexes.allSatisfy { coordinator.entries[$0].notice != nil }, "expanding restores selected checkboxes without selecting headers")
        let parentIndex = coordinator.entries.firstIndex { $0.group?.thread == "parent" }!
        let groupCell = coordinator.tableView(table, viewFor: table.tableColumns[0], row: parentIndex) as! NoticeGroupCell
        groupCell.open?()
        try await wait { launches == 2 }
        try check(observer.snapshot(InboxQuery(section: .recent)).taskRows.contains { $0.task.thread == "parent" }, "explicit parent opening is recorded separately")
        inbox.stop()
    }
    @MainActor static func accessChecks() async throws {
        let name = "local.codex.inbox.tests.preferences." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let access = AppAccess(defaults: defaults)
        try check(access.configuration == AppAccessConfiguration(), "access defaults preserve menu bar only")
        try check(!access.setMenuBar(false), "last entry point cannot be disabled")
        try check(access.setDock(true), "both entry points are supported")
        try check(AppAccess(defaults: UserDefaults(suiteName: name)).configuration == access.configuration, "preferences reload with both enabled")
        try check(access.setMenuBar(false), "Dock-only is supported")
        try check(!access.setDock(false), "Dock-only cannot be stranded")
        try check(AppAccess(defaults: UserDefaults(suiteName: name)).configuration == access.configuration, "Dock-only survives preference reload")
        defaults.set(["menuBar": false, "dock": false], forKey: AppAccess.preferenceKey)
        try check(AppAccess(defaults: defaults).configuration == AppAccessConfiguration(), "invalid saved preferences recover established defaults")
        defaults.set("invalid", forKey: AppAccess.preferenceKey)
        try check(AppAccess(defaults: defaults).configuration == AppAccessConfiguration(), "malformed saved preferences recover safely")

        let localAccess = AppAccess(defaults: nil), inbox = Inbox(demo: true)
        var policies: [Bool] = [], revealed: [NSWindow] = []
        let presentation = InboxPresentation(inbox: inbox, access: localAccess, systemUI: false,
            screens: { [NSRect(x: 0, y: 0, width: 1440, height: 900)] },
            applyPolicy: { policies.append($0); return true }, reveal: { revealed.append($0) })
        defer { presentation.shutdown(); inbox.stop() }
        let frame = presentation.mainWindow.frame
        let originalIDs = inbox.snapshot.recentActionable.map(\.id)
        inbox.setSection(.done)
        try check(inbox.snapshot.recentActionable.map(\.id) == originalIDs, "card uses global actionable notices independent of main filters")
        try check(revealed.isEmpty && !presentation.mainWindow.isVisible, "background setup does not present a window")
        for _ in 0..<20 { localAccess.setDock(true); localAccess.setMenuBar(false); localAccess.setMenuBar(true); localAccess.setDock(false) }
        localAccess.setDock(true)
        try await wait { policies.last == true }
        try check(policies.count <= 3, "rapid preference changes coalesce without stale policy updates")
        try check(inbox.query.section == .done && presentation.mainWindow.frame == frame, "mode changes preserve query and window state")
        try check(revealed.isEmpty, "access changes do not activate any window")
        try check((presentation.mainWindow.contentView as? NSHostingView<InboxView>)?.rootView.inbox === inbox, "main view borrows the app-owned Inbox")
        let card = (presentation.popover.contentViewController as! NSHostingController<InboxCard>).rootView
        try check(card.inbox === inbox && presentation.popover.behavior == .transient, "card shares state and uses native transient dismissal")
        let count = inbox.pendingCount, row = inbox.snapshot.recentActionable[0]
        card.review(row)
        try check(inbox.pendingCount == count && inbox.detailNotice?.seen == row.seen, "card review changes neither Seen nor Done")
        try check(revealed.last === presentation.mainWindow, "card review opens the existing Inbox window")
        presentation.mainWindow.close()
        for _ in 0..<4 { card.openInbox(); presentation.closeCard() }
        try check(revealed.allSatisfy { $0 === presentation.mainWindow }, "repeated reopen after close reuses one main window")
        inbox.perform(.done, ids: [row.id])
        try check(card.inbox.pendingCount == count - 1 && !card.inbox.snapshot.recentActionable.contains(where: { $0.id == row.id }), "main actions update the card's shared snapshot")
        presentation.showSettings(); let settings = presentation.settingsWindow
        settings?.close(); presentation.showSettings()
        try check(settings === presentation.settingsWindow, "settings reuse one window")
        let openCount = revealed.count
        localAccess.setDock(false); localAccess.recoverRemovedStatusItem()
        try await wait { policies.last == true }
        try check(localAccess.configuration == AppAccessConfiguration(menuBar: false, dock: true) && revealed.count == openCount, "status item removal recovers Dock access without focus")

        let failedAccess = AppAccess(defaults: nil)
        let failedPresentation = InboxPresentation(inbox: inbox, access: failedAccess, systemUI: false,
            applyPolicy: { !$0 }, reveal: { _ in fatalError("Policy recovery must not reveal a window") })
        failedAccess.setDock(true)
        try await wait { !failedAccess.message.isEmpty }
        try check(failedAccess.configuration == AppAccessConfiguration(), "failed Dock policy retains a reachable menu bar configuration")
        failedPresentation.shutdown()

        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let valid = NSRect(x: 80, y: 100, width: 960, height: 730)
        try check(InboxWindowPlacement.recover(valid, screens: [screen]) == valid, "valid saved window position is preserved")
        let stranded = NSRect(x: 3000, y: 100, width: 960, height: 730)
        try check(screen.contains(InboxWindowPlacement.recover(stranded, screens: [screen])), "removed-monitor position recovers onto available display")
        try check(InboxWindowPlacement.recover(valid, screens: []) == valid, "transient lack of display information does not move a window")
        print("Access checks passed: preferences, reachability, shared card state, window reuse, no-focus policy changes, and display recovery. Presentation and activation were injected; no user windows were shown.")
    }
    @MainActor static func soundAndCatchupChecks(_ root: URL) async throws {
        let domain = "local.codex.inbox.tests.sounds." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(false, forKey: "sound") // Preserve the existing mute preference.
        defaults.set("missing-sound", forKey: "alertSound")
        var sounds: [String] = [], banners: [String] = []
        let directory = root.appendingPathComponent("sound-catchup")
        let inbox = Inbox(directory: directory, bannerScheduler: { notice, _, done in
            banners.append(notice.id); done(nil)
        }, soundPlayer: { sounds.append($0) }, defaults: defaults)
        defer { inbox.stop() }
        try await wait { inbox.ready }
        try check(!inbox.sound && inbox.alertSound == .glass, "legacy mute loads; invalid sound falls back to Glass")
        inbox.previewSound()
        try check(sounds.isEmpty, "mute suppresses preview")
        func deliver(_ message: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: message)
            await withCheckedContinuation { continuation in
                inbox.receiveLine(data, completion: { continuation.resume() })
            }
            try check(inbox.storageError.isEmpty, "catch-up envelope commits")
        }
        func event(_ id: String, historical: Bool = false) throws -> Any {
            var value = notice(id); value.historical = historical
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        let request: [String: Any] = ["identity": "pending-at-start", "opaque": true, "kind": "approval", "body": "Approve?"]
        try await deliver(["type": "event", "event": event("missed"), "announce": false])
        try await deliver(["type": "requests", "thread": "startup", "host": "local", "requests": [request], "announce": false])
        try await wait { inbox.snapshot.total == 2 }
        try check(inbox.pendingCount == 2 && sounds.isEmpty && banners.isEmpty, "missed events and initial requests remain actionable without sounds or banners")
        try await deliver(["type": "event", "event": event("muted-live"), "announce": true])
        try await wait { banners.count == 1 }
        try check(sounds.isEmpty, "muted live alerts still schedule banners without playing sounds")
        inbox.sound = true; inbox.alertSound = .ping
        inbox.previewSound()
        try check(sounds == ["Ping"], "explicit preview uses the selected sound")
        try await deliver(["type": "requests", "thread": "live", "host": "remote", "requests": [request], "announce": true])
        try await wait { banners.count == 2 }
        try check(sounds == ["Ping", "Ping"], "new live request announces with the selected sound")
        try await deliver(["type": "event", "event": event("missed"), "announce": true])
        try await deliver(["type": "event", "event": event("unknown-provenance")])
        try await deliver(["type": "requests", "thread": "reconnect", "host": "local", "requests": [request], "announce": false])
        try await deliver(["type": "event", "event": event("historical", historical: true), "announce": true])
        try await wait { inbox.snapshot.total == 7 }
        try check(inbox.pendingCount == 7 && banners.count == 2 && sounds.count == 2, "replay, missing provenance, reconnect snapshots and historical events are silent without losing records")
        let restarted = Inbox(directory: directory, alertsEnabled: false, soundPlayer: { sounds.append($0) }, defaults: defaults)
        defer { restarted.stop() }
        try await wait { restarted.ready }
        try check(restarted.sound && restarted.alertSound == .ping, "selected sound and unmute persist across restart")
        restarted.sound = false
        let muted = Inbox(demo: true, defaults: defaults)
        try check(!muted.sound && muted.alertSound == .ping, "mute persists across restart")
        for option in InboxAlertSound.allCases {
            try check(FileManager.default.fileExists(atPath: "/System/Library/Sounds/" + option.rawValue + ".aiff"), "offered system sound exists: " + option.rawValue)
        }
        print("Sound checks passed: mute persistence, selected sound, silent catch-up/reconnect, and live alerts. Sound and banner delivery were injected; nothing played or opened.")
    }
    @MainActor static func run() async throws {
        if let index = CommandLine.arguments.firstIndex(of: "--migration-copy"), CommandLine.arguments.count > index + 1 {
            let store = try InboxStore(path: CommandLine.arguments[index + 1])
            let snapshot = try store.snapshot(InboxQuery())
            let entries = NoticeGrouping.entries(snapshot.notices, catalog: snapshot.taskCatalog)
            try check(entries.compactMap(\.notice).count == snapshot.notices.count, "copied inbox grouping preserves every loaded alert")
            let incorrectlyOwned = snapshot.taskCatalog.values.filter { row in
                row.task.threadSource == "user" && row.isSubagent && row.relations.allSatisfy { $0.kind != "subagent" }
            }
            try check(incorrectlyOwned.isEmpty, "copied user chats are not reclassified by old activity records")
            print("Copied inbox: \(snapshot.total) notices; \(snapshot.activityCount) journal entries; \(snapshot.taskCatalog.values.filter(\.isSubagent).count) subagents; \(entries.compactMap(\.group).count) parent groups on the loaded page; \(snapshot.sectionCounts[.running] ?? 0) running; \(snapshot.sectionCounts[.unconfirmed] ?? 0) unconfirmed. Grouping preserved every loaded alert.")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-features-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if CommandLine.arguments.contains("--access-only") { try await accessChecks(); return }
        if CommandLine.arguments.contains("--sound-only") { try await soundAndCatchupChecks(root); return }
        try stateChecks(root); try viewChecks(); try groupingChecks(); try runningProjectChecks(); try migrationChecks(root); try savedMapChecks(); try transcriptChecks()
        try await refreshChecks(root)
        try await controllerAndNativeChecks(root)
        try await accessChecks()
        try await soundAndCatchupChecks(root)
        print("Feature checks passed: atomic bulk actions, seen/done/undo ordering, migrations, view filters, task provenance, runtime ordering, recent opens, native selection and stable refresh. No apps opened.")
    }
    @MainActor static func savedMapChecks() throws {
        let parent = SavedMapActor(id: "parent", name: "Parent", isSubagent: false)
        let child = SavedMapActor(id: "child", name: "Reviewer", isSubagent: true, parent: "parent")
        let input = SavedMapMessage(id: "input", thread: "parent", turn: "p-turn", item: "input", at: 100, role: "user", preview: "Request", ordinal: 1)
        let final = SavedMapMessage(id: "final", thread: "child", turn: "c-turn", item: "final", at: 150, role: "assistant", phase: "final_answer", preview: "Review", ordinal: 2)
        let call = SavedMapHandoff(id: "call", sender: "parent", senderTurn: "p-turn", recipient: "child", at: 110, kind: "followup_task", callID: "call", preview: "Inspect", source: "Fixture", evidence: "Recorded call")
        let snapshot = ConversationMapSnapshot(root: parent, requested: "parent", actors: [parent, child], familyCount: 2, turns: [], messages: [input, final], handoffs: [call], start: 90, end: 200, capturedAt: 200, warnings: [], source: "Fixture")
        let model = ConversationMapModel(preview: snapshot)
        try check(model.selectedMessage?.id == final.id, "saved map initially selects latest recorded message across actors")
        model.select(call)
        try check(model.selectedMessage == nil && model.selectedHandoff?.recipient == child.id && model.selectedHandoff?.senderTurn == "p-turn", "handoff selection preserves recorded sender-turn/thread endpoints and clears message selection")
        model.select(input)
        try check(model.selectedHandoff == nil && model.selectedMessage?.thread == parent.id, "message selection clears the traced handoff")
        let trace = ConversationMapModel(preview: snapshot, tracePreview: true)
        try check(trace.selectedHandoff?.id == call.id && trace.selectedMessage == nil, "offscreen trace uses a recorded call")
    }
    @MainActor static func transcriptChecks() throws {
        let parent = TaskIdentity(thread: "p", title: "Parent", projectID: "project", projectName: "Project")
        let child = TaskIdentity(thread: "c", title: "Reviewer", projectID: "project", projectName: "Project", threadSource: "subagent")
        let fork = TaskIdentity(thread: "f", title: "Separate chat", threadSource: "user")
        var snapshot = InboxSnapshot()
        snapshot.taskCatalog[parent.key] = StoredTask(task: parent)
        snapshot.taskCatalog[child.key] = StoredTask(task: child, parentKey: parent.key, parentKind: "subagent", isSubagent: true)
        snapshot.taskCatalog[fork.key] = StoredTask(task: fork, parentKey: parent.key, parentKind: "created")
        func alert(_ id: String, _ task: TaskIdentity, at: Double, kind: String = "completion") -> StoredNotice {
            var notice = self.notice(id, thread: task.thread, kind: kind); notice.created = at; notice.turn = "turn"
            return StoredNotice(notice: notice, task: task, needsAttention: true, previouslySeen: false)
        }
        let mainAlert = alert("main-alert", parent, at: 400)
        let childAlert = alert("child-alert", child, at: 300)
        snapshot.notices = [childAlert, mainAlert, alert("fork-alert", fork, at: 200)]
        let families = TranscriptGrouping.families(snapshot)
        try check(families.count == 2 && families[0].task.key == parent.key && Set(families[0].notices.map(\.id)) == ["main-alert", "child-alert"], "default saved-message list joins subagents with the parent and keeps ordinary created chats separate")
        func message(_ id: String, _ thread: String, at: Double?, ordinal: Int, final: Bool = false) -> SavedTranscriptMessage {
            SavedTranscriptMessage(message: SavedMapMessage(id: id, thread: thread, turn: "turn", item: id, at: at, role: "assistant", phase: final ? "final_answer" : "commentary", preview: "Saved text " + id, ordinal: ordinal), turnNumber: 3, finalForTurn: final)
        }
        let saved = [message("parent-final", "p", at: 400, ordinal: 4, final: true), message("child-final", "c", at: 300, ordinal: 2, final: true), message("parent-progress", "p", at: 250, ordinal: 3), message("child-unknown", "c", at: nil, ordinal: 3)]
        let rows = TranscriptChronology.rows(saved, notices: [mainAlert, childAlert])
        try check(rows.entries.compactMap { $0.saved?.id } == ["parent-progress", "child-final", "parent-final", "child-unknown"], "default list interleaves real parent and agent messages oldest first, with unknown times last")
        try check(rows.entries.filter { $0.alert != nil }.isEmpty && rows.entries.flatMap(\.notices).map(\.id).sorted() == ["child-alert", "main-alert"], "completed-turn alerts attach to the recorded final item exactly once instead of duplicating its reply")
        let unmatched = TranscriptChronology.rows([message("not-final", "p", at: 400, ordinal: 3)], notices: [mainAlert])
        try check(unmatched.entries.contains { $0.alert?.id == mainAlert.id }, "a similar timestamp or message body does not imply an alert belongs to a saved message")
        var olderAlert = alert("older", parent, at: 10); olderAlert.notice.turn = "old-turn"
        let old = TranscriptChronology.rows(saved, notices: [olderAlert])
        try check(old.otherAlerts == 1 && old.entries.filter { $0.alert != nil }.isEmpty, "alerts outside the loaded message history remain explicitly counted rather than inserted across an unexplained history gap")
        let question = alert("local:p:question:q:0", parent, at: 350, kind: "question")
        let qRows = TranscriptChronology.rows([message("q", "p", at: 350, ordinal: 4)], notices: [question])
        try check(qRows.entries.count == 1 && qRows.entries[0].notices.map(\.id) == [question.id], "question actions attach by recorded message identity")
        let misleading = alert("local:p:question:q:extra:0", parent, at: 350, kind: "question")
        try check(TranscriptChronology.rows([message("q", "p", at: 350, ordinal: 4)], notices: [misleading]).entries.count == 2, "a prefix resembling a message ID does not create a false question association")
        let before = snapshot.notices
        _ = TranscriptChronology.rows(saved, notices: before)
        try check(snapshot.notices == before && snapshot.notices.allSatisfy { !$0.seen && $0.needsAttention }, "reading and arranging saved messages preserves every alert identity and Seen/Done decision")
        let sent = SavedMapHandoff(id: "sent", sender: "p", senderTurn: "turn", recipient: "c", at: 275, kind: "send_message", callID: "sent", preview: "Check this", source: "Fixture", evidence: "Recorded call")
        let returned = SavedMapHandoff(id: "returned", sender: "c", senderTurn: "child-turn", recipient: "p", at: 350, kind: "send_message", callID: "returned", preview: "Review done", source: "Fixture", evidence: "Recorded call")
        let spawn = SavedMapHandoff(id: "spawn", sender: "c", senderTurn: "child-turn", recipient: "grandchild", at: 280, kind: "spawn_agent", callID: "spawn", preview: "Test this", source: "Fixture", evidence: "Recorded spawn")
        let directed = TranscriptChronology.rows(saved, notices: [mainAlert, childAlert], routing: [returned, sent, spawn, sent])
        try check(directed.entries.map(\.id) == ["message:parent-progress", "route:sent:c", "route:spawn:grandchild", "message:child-final", "route:returned:p", "message:parent-final", "message:child-unknown"], "recorded sends, returns and nested spawns interleave at their own timestamps with one stable row per event")
        try check(directed.entries.first { $0.route?.id == returned.id }?.route?.senderTurn == "child-turn", "a recorded return retains the child sender’s own turn rather than assigning a parent turn")
        try check(directed.entries.flatMap(\.notices).map(\.id).sorted() == ["child-alert", "main-alert"] && snapshot.notices == before, "routing entries preserve alert associations and all Seen/Done state")
        snapshot.taskCatalog[parent.key] = StoredTask(task: parent, parentKey: child.key, parentKind: "subagent", isSubagent: true)
        try check(TranscriptGrouping.families(snapshot).count == 3, "cyclic agent ancestry keeps the original conversations separate instead of inventing a family")
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { FileHandle.standardError.write(Data(("Feature checks failed: \(error)\n").utf8)); exit(1) }
        }
        app.run()
    }
}
