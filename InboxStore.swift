import Foundation
import SQLite3

private let sqlTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
enum SQLValue {
    case text(String), number(Double), integer(Int64), null
    static func optional(_ value: String?) -> SQLValue { value.map(Self.text) ?? .null }
    static func optional(_ value: Double?) -> SQLValue { value.map(Self.number) ?? .null }
    static func optional(_ value: Int64?) -> SQLValue { value.map(Self.integer) ?? .null }
}

enum StoreError: Error, LocalizedError {
    case database(String)
    var errorDescription: String? { if case .database(let message) = self { return message }; return nil }
}

/// Accessed only on the inbox's serial storage queue. The journal and its current
/// state are committed together. No retention policy or history-deleting query.
final class InboxStore {
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw StoreError.database("Could not open the activity database.")
        }
        sqlite3_busy_timeout(db, 1500)
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS tasks (key TEXT PRIMARY KEY, host TEXT NOT NULL, thread TEXT NOT NULL, title TEXT NOT NULL, project_key TEXT NOT NULL, project_name TEXT, payload TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS activity (seq INTEGER PRIMARY KEY AUTOINCREMENT, dedup TEXT UNIQUE, notice_id TEXT, task_key TEXT NOT NULL, task_json TEXT NOT NULL, project_key TEXT NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL, time_json TEXT NOT NULL, source_at REAL)")
            try execute("CREATE INDEX IF NOT EXISTS activity_task ON activity(task_key,seq DESC)")
            try execute("CREATE INDEX IF NOT EXISTS activity_notice ON activity(notice_id,seq DESC)")
            try execute("CREATE INDEX IF NOT EXISTS activity_project ON activity(project_key,seq DESC)")
            try execute("CREATE TABLE IF NOT EXISTS notices (id TEXT PRIMARY KEY, task_key TEXT NOT NULL REFERENCES tasks(key), payload TEXT NOT NULL, first_seq INTEGER NOT NULL, attention INTEGER NOT NULL, done_reason TEXT, clicked_at REAL, opened_at REAL, legacy_seen INTEGER NOT NULL DEFAULT 0, reopened_seq INTEGER NOT NULL DEFAULT 0, reopened_at REAL)")
            try execute("CREATE INDEX IF NOT EXISTS notices_attention ON notices(attention,first_seq DESC)")
            try execute("CREATE INDEX IF NOT EXISTS notices_task ON notices(task_key,first_seq)")
            try execute("CREATE TABLE IF NOT EXISTS replies (id TEXT PRIMARY KEY, task_key TEXT NOT NULL, payload TEXT NOT NULL, first_seq INTEGER NOT NULL, time_json TEXT NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS replies_task ON replies(task_key,first_seq)")
            try migrateSelectionState()
        } catch { sqlite3_close(db); db = nil; throw error }
        if path != ":memory:" {
            for file in [path, path + "-wal", path + "-shm"] where FileManager.default.fileExists(atPath: file) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
            }
        }
    }
    deinit { sqlite3_close(db) }

    func failure() -> StoreError { .database(String(cString: sqlite3_errmsg(db))) }
    @discardableResult func statement<T>(_ sql: String, _ values: [SQLValue] = [], _ body: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw failure() }
        defer { sqlite3_finalize(prepared) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                let length = text.utf8.count
                guard length <= Int(Int32.max) else { throw StoreError.database("Text exceeds SQLite's supported binding length.") }
                result = text.withCString { sqlite3_bind_text(prepared, index, $0, Int32(length), sqlTransient) }
            case .number(let number): result = sqlite3_bind_double(prepared, index, number)
            case .integer(let number): result = sqlite3_bind_int64(prepared, index, number)
            case .null: result = sqlite3_bind_null(prepared, index)
            }
            guard result == SQLITE_OK else { throw failure() }
        }
        return try body(prepared)
    }
    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        try statement(sql, values) { s in
            var result = sqlite3_step(s)
            while result == SQLITE_ROW { result = sqlite3_step(s) }
            guard result == SQLITE_DONE else { throw failure() }
        }
    }
    func rows<T>(_ sql: String, _ values: [SQLValue] = [], _ map: (OpaquePointer) throws -> T) throws -> [T] {
        try statement(sql, values) { s in
            var result: [T] = []
            while true {
                let step = sqlite3_step(s)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW else { throw failure() }
                result.append(try map(s))
            }
        }
    }
    func text(_ s: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(s, column).map { String(decoding: UnsafeBufferPointer(start: $0, count: Int(sqlite3_column_bytes(s, column))), as: UTF8.self) } ?? "" }
    func optionalText(_ s: OpaquePointer, _ column: Int32) -> String? { sqlite3_column_type(s, column) == SQLITE_NULL ? nil : text(s, column) }
    func optionalNumber(_ s: OpaquePointer, _ column: Int32) -> Double? { sqlite3_column_type(s, column) == SQLITE_NULL ? nil : sqlite3_column_double(s, column) }
    func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T { try decoder.decode(type, from: Data(value.utf8)) }
    func count(_ sql: String, _ values: [SQLValue] = []) throws -> Int { try rows(sql, values) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func metadata(_ key: String) throws -> String? { try rows("SELECT value FROM meta WHERE key=?", [.text(key)]) { text($0, 0) }.first }
    func setMetadata(_ key: String, _ value: String) throws { try execute("INSERT INTO meta VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)]) }

    func identity(_ notice: Notice) throws -> TaskIdentity {
        let fallback = TaskIdentity(thread: notice.thread, host: notice.host, title: notice.title)
        return try task(fallback.key) ?? fallback
    }
    func task(_ key: String) throws -> TaskIdentity? { try rows("SELECT payload FROM tasks WHERE key=?", [.text(key)]) { try decode(TaskIdentity.self, text($0, 0)) }.first }
    func saveTask(_ task: TaskIdentity) throws {
        try execute("INSERT INTO tasks VALUES (?,?,?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET title=excluded.title,project_key=excluded.project_key,project_name=excluded.project_name,payload=excluded.payload", [.text(task.key), .text(task.host), .text(task.thread), .text(task.title), .text(task.projectKey), .optional(task.projectName), .text(try encode(task))])
    }
    func updateTasks(_ tasks: [TaskIdentity], at time: EventTime) throws {
        try transaction {
            for var value in tasks {
                let old = try task(value.key)
                value.origin = value.origin ?? old?.origin
                value.originator = value.originator ?? old?.originator
                value.threadSource = value.threadSource ?? old?.threadSource
                value.agentNickname = value.agentNickname ?? old?.agentNickname
                value.agentRole = value.agentRole ?? old?.agentRole
                guard old != value else { continue }
                try saveTask(value)
                if let old, try count("SELECT COUNT(*) FROM notices WHERE task_key=?", [.text(value.key)]) > 0 {
                    let detail = old.projectKey != value.projectKey ? "Project changed from \(old.projectName ?? "No project") to \(value.projectName ?? "No project")." : "Task name or project name updated."
                    try append(kind: "task_updated", task: value, detail: detail, at: time)
                }
            }
        }
    }
    @discardableResult func append(kind: String, noticeID: String? = nil, task: TaskIdentity, detail: String, at time: EventTime, sourceAt: Double? = nil, dedup: String? = nil) throws -> Int64 {
        try execute("INSERT INTO activity(dedup,notice_id,task_key,task_json,project_key,kind,detail,time_json,source_at) VALUES (?,?,?,?,?,?,?,?,?)", [.optional(dedup), .optional(noticeID), .text(task.key), .text(try encode(task)), .text(task.historyProjectKey), .text(kind), .text(detail), .text(try encode(time)), .optional(sourceAt)])
        return sqlite3_last_insert_rowid(db)
    }
    func record(kind: String, noticeID: String?, task: TaskIdentity, detail: String, at time: EventTime, attemptID: String? = nil) throws {
        try transaction {
            if try self.task(task.key) == nil { try saveTask(task) }
            let seq = try append(kind: kind, noticeID: noticeID, task: task, detail: detail, at: time)
            if let attemptID { try execute("UPDATE activity SET attempt_id=? WHERE seq=?", [.text(attemptID), .integer(seq)]) }
            if kind == "open_clicked" {
                if let noticeID { try execute("UPDATE notices SET clicked_at=?,seen=1,seen_version=? WHERE id=?", [.number(time.at), .integer(seq), .text(noticeID)]) }
                try execute("INSERT INTO task_visits(task_key,clicked_at,click_seq,attempt_id,outcome,detail) VALUES (?,?,?,?,?,?) ON CONFLICT(task_key) DO UPDATE SET clicked_at=excluded.clicked_at,click_seq=excluded.click_seq,attempt_id=excluded.attempt_id,outcome=excluded.outcome,detail=excluded.detail", [.text(task.key), .number(time.at), .integer(seq), .optional(attemptID), .text("unknown"), .text("Opening was requested; acceptance is not recorded.")])
            }
            if kind == "open_accepted" || kind == "open_failed" {
                let current = try rows("SELECT attempt_id FROM task_visits WHERE task_key=?", [.text(task.key)]) { optionalText($0, 0) }.first
                if attemptID == nil || current == attemptID {
                    try execute("UPDATE task_visits SET outcome=?,detail=? WHERE task_key=?", [.text(kind == "open_accepted" ? "accepted" : "failed"), .text(detail), .text(task.key)])
                    if let noticeID, kind == "open_accepted" { try execute("UPDATE notices SET opened_at=? WHERE id=?", [.number(time.at), .text(noticeID)]) }
                }
            }
        }
    }
    func setDone(_ id: String, done: Bool, at time: EventTime) throws {
        _ = try applyBatch([id], action: done ? .done : .reopen, at: time)
    }

    /// Returns true only for a newly recorded notification. Stream replay is not
    /// a new arrival, and must not overwrite manual attention decisions.
    @discardableResult func ingest(_ event: Notice, at time: EventTime) throws -> Bool {
        try transaction { try ingestValue(event, at: time) }
    }
    func ingestValue(_ event: Notice, at time: EventTime) throws -> Bool {
            let old = try notice(event.id)
            let task = try identity(event)
            if try self.task(task.key) == nil { try saveTask(task) }
            var value = event
            if let old {
                // A later history projection can provide better source ordering.
                value.sourceOrdinal = event.sourceOrdinal ?? old.notice.sourceOrdinal
                value.terminalStatus = event.terminalStatus ?? old.notice.terminalStatus
                if event.timeSource != "codex" || old.notice.timeSource == "codex" {
                    value.created = old.notice.created; value.timeSource = old.notice.timeSource
                }
                value.historical = old.notice.historical
                if old.notice.deadline != nil && (value.deadline == nil || value.estimated == true) {
                    value.deadline = old.notice.deadline; value.estimated = old.notice.estimated
                }
                if value.resolution == nil, old.notice.resolved { value.resolution = old.notice.resolution; value.resolved = true }
                guard value != old.notice else { return false }
                try execute("UPDATE notices SET payload=? WHERE id=?", [.text(try encode(value)), .text(event.id)])
                if value.body != old.notice.body || value.kind != old.notice.kind {
                    try append(kind: "notification_updated", noticeID: value.id, task: task, detail: value.body, at: time)
                }
                if value.resolution != old.notice.resolution, let resolution = value.resolution {
                    try append(kind: resolution == "answered" ? "answer_recorded" : "request_ended", noticeID: value.id, task: task, detail: resolution == "answered" ? "Codex recorded an answer to this question." : "The request is no longer pending in Codex. Its outcome was not supplied.", at: time)
                    // Resolution text alone has no answer ordering evidence. Durable replies reconcile below.
                }
            } else {
                let seq = try append(kind: event.historical == true ? "imported" : "notification", noticeID: event.id, task: task, detail: event.body, at: time, sourceAt: event.timeSource == "codex" ? event.created : nil, dedup: "notice:" + event.id)
                // Recovering an old alert does not prove it was handled. A later
                // source reply can settle it; otherwise it still needs attention.
                let reason: String? = event.resolution == "answered" ? "answer" : nil
                try execute("INSERT INTO notices(id,task_key,payload,first_seq,attention,done_reason) VALUES (?,?,?,?,?,?)", [.text(event.id), .text(task.key), .text(try encode(event)), .integer(seq), .integer(reason == nil ? 1 : 0), .optional(reason)])
            }
            try reconcile(event.id, at: time)
            return old == nil
    }

    func updateTitle(thread: String, host: String, title: String, at time: EventTime) throws {
        var value = try task(host + "\u{1f}" + thread) ?? TaskIdentity(thread: thread, host: host, title: title)
        value.title = title
        try updateTasks([value], at: time)
    }

    /// Only accepted request sets establish presence/absence. Disconnect and
    /// subscription retirement never call this with an invented empty set.
    func ingestRequests(_ requests: [RequestObservation], thread: String, host: String, at time: EventTime) throws -> [Notice] {
        try transaction {
            let scope = try encode([host, thread])
            let prefix = "request:" + Data(scope.utf8).base64EncodedString() + ":"
            var present = Set<String>(), arrivals: [Notice] = []
            for request in requests {
                let key = prefix + Data(request.identity.utf8).base64EncodedString()
                present.insert(key)
                let old = try metadata(key).map { try decode(RequestOccurrence.self, $0) }
                let occurrence = old?.present == true ? old! : RequestOccurrence(id: host + ":" + thread + ":request:" + UUID().uuidString, present: true)
                try setMetadata(key, try encode(occurrence))
                let task = try self.task(host + "\u{1f}" + thread) ?? TaskIdentity(thread: thread, host: host, title: "Codex task")
                let notice = Notice(id: occurrence.id, thread: thread, host: host, kind: request.kind, title: task.title, body: request.body, created: time.deviceAt, resolved: false, historical: false, deadline: request.deadline, estimated: request.estimated, timerUnavailable: request.timerUnavailable, timeSource: "observed", identityAmbiguous: request.opaque)
                if try ingestValue(notice, at: time) { arrivals.append(notice) }
            }
            // A statement walks prior slots without retaining historical payloads.
            try each("SELECT key,value FROM meta WHERE substr(key,1,?)=?", [.integer(Int64(prefix.count)), .text(prefix)]) { s in
                let key = text(s, 0)
                var old = try decode(RequestOccurrence.self, text(s, 1))
                if old.present && !present.contains(key) {
                    old.present = false; try setMetadata(key, try encode(old))
                    if var value = try notice(old.id)?.notice {
                        value.resolved = true; value.resolution = "request_ended"
                        _ = try ingestValue(value, at: time)
                    }
                }
                return true
            }
            return arrivals
        }
    }

    func each(_ sql: String, _ values: [SQLValue] = [], _ body: (OpaquePointer) throws -> Bool) throws {
        try statement(sql, values) { s in
            while true {
                let result = sqlite3_step(s)
                if result == SQLITE_DONE { return }
                guard result == SQLITE_ROW else { throw failure() }
                if try !body(s) { return }
            }
        }
    }
    func canonicalReply(_ id: String) throws -> String {
        var current = id, seen = Set<String>()
        while let next = try metadata("reply-merged:" + current) {
            guard seen.insert(current).inserted else { throw StoreError.database("Reply alias cycle; original records preserved.") }
            current = next
        }
        return current
    }
    func aliasKey(_ reply: Reply, _ alias: String) throws -> String {
        "reply-alias:" + (try encode([reply.host, reply.thread, alias]))
    }
    func ingestReply(_ reply: Reply, at time: EventTime) throws {
        try transaction {
            let key = reply.host + "\u{1f}" + reply.thread
            var ids: Set<String> = [try canonicalReply(reply.id)]
            for alias in reply.aliases ?? [] {
                if let id = try metadata(aliasKey(reply, alias)) { ids.insert(try canonicalReply(id)) }
            }
            var candidates: [(Reply, Int64)] = []
            for id in ids {
                if let row = try rows("SELECT payload,first_seq FROM replies WHERE id=? AND task_key=?", [.text(id), .text(key)], { (try decode(Reply.self, text($0, 0)), sqlite3_column_int64($0, 1)) }).first { candidates.append(row) }
            }
            candidates.sort { $0.1 < $1.1 }
            var value = reply
            if let (earliest, _) = candidates.first {
                value.id = earliest.id
                value.created = earliest.created ?? reply.created
                value.sourceOrdinal = earliest.sourceOrdinal ?? reply.sourceOrdinal
                value.live = earliest.live; value.provenance = earliest.provenance
                value.aliases = Array(Set((reply.aliases ?? []) + candidates.flatMap { $0.0.aliases ?? [] })).sorted()
                value.answeredQuestionIDs = Array(Set((reply.answeredQuestionIDs ?? []) + candidates.flatMap { $0.0.answeredQuestionIDs ?? [] })).sorted()
                try execute("UPDATE replies SET payload=? WHERE id=?", [.text(try encode(value)), .text(value.id)])
                for (duplicate, _) in candidates.dropFirst() {
                    try setMetadata("reply-merged:" + duplicate.id, value.id)
                }
            } else {
                let task = try self.task(key) ?? TaskIdentity(thread: reply.thread, host: reply.host, title: "Codex task")
                if try self.task(key) == nil { try saveTask(task) }
                let seq = try append(kind: "message_sent", task: task, detail: reply.body, at: time, sourceAt: reply.created, dedup: "reply:" + reply.id)
                try execute("INSERT INTO replies VALUES (?,?,?,?,?)", [.text(reply.id), .text(key), .text(try encode(reply)), .integer(seq), .text(try encode(time))])
            }
            for alias in value.aliases ?? [] { try setMetadata(aliasKey(value, alias), value.id) }
            if reply.id != value.id { try setMetadata("reply-merged:" + reply.id, value.id) }
            var last: Int64 = 0
            while true {
                let page = try rows("SELECT id,first_seq FROM notices WHERE task_key=? AND attention=1 AND first_seq>? ORDER BY first_seq LIMIT 64", [.text(key), .integer(last)]) { (text($0, 0), sqlite3_column_int64($0, 1)) }
                guard !page.isEmpty else { break }
                for (id, _) in page { try reconcile(id, at: time) }
                last = page.last!.1
            }
        }
    }

    func reconcile(_ id: String, at observed: EventTime) throws {
        guard let row = try notice(id), row.needsAttention else { return }
        let markers = try rows("SELECT first_seq,reopened_seq,reopened_at FROM notices WHERE id=?", [.text(id)]) { (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1), optionalNumber($0, 2)) }.first!
        try each("SELECT payload,first_seq FROM replies WHERE task_key=? ORDER BY first_seq DESC", [.text(row.task.key)]) { s in
            let reply = try decode(Reply.self, text(s, 0)), seq = sqlite3_column_int64(s, 1)
            guard try canonicalReply(reply.id) == reply.id else { return true }
            let fresh = reply.provenance == "new_action"
            // Discovery, aliases and answer markup all use this same manual guard.
            if markers.1 > 0 {
                if seq <= markers.1 { return true }
                if let created = reply.created, let reopened = markers.2 {
                    if created <= reopened { return true }
                } else if !fresh { return true }
            }
            let after: Bool
            if let n = row.notice.sourceOrdinal, let r = reply.sourceOrdinal { after = r > n }
            else if row.notice.timeSource != "unknown", let created = reply.created { after = created > row.notice.created }
            else { after = fresh && seq > markers.0 }
            guard after else { return true }
            let explicit = row.notice.questionID.map { (reply.answeredQuestionIDs ?? []).contains($0) } ?? false
            let actionSeq = try append(kind: explicit ? "answer_recorded" : "done_after_reply", noticeID: id, task: row.task, detail: explicit ? "Codex recorded an ordered answer to this question." : "A message was sent in this task after the notification. This does not assert that every question was answered.", at: observed, sourceAt: reply.created)
            try execute("UPDATE notices SET attention=0,done_reason=?,attention_version=? WHERE id=?", [.text(explicit ? "answer" : "reply"), .integer(actionSeq), .text(id)])
            return false
        }
    }

    func bannerState(_ noticeID: String) throws -> BannerState? {
        try rows("SELECT detail FROM activity WHERE notice_id=? AND kind IN ('banner_attempt','banner_accepted','banner_failed') ORDER BY seq DESC LIMIT 1", [.text(noticeID)]) { try decode(BannerState.self, text($0, 0)) }.first
    }
    func beginBanner(_ noticeID: String, attemptID: String, at time: EventTime) throws {
        guard let row = try notice(noticeID) else { throw StoreError.database("Banner notice is missing.") }
        try append(kind: "banner_attempt", noticeID: noticeID, task: row.task, detail: try encode(BannerState(attemptID: attemptID, state: "unknown", detail: "Banner scheduling started; acceptance is not yet known.")), at: time, dedup: "banner:" + attemptID)
    }
    func finishBanner(_ noticeID: String, attemptID: String, error: String?, at time: EventTime) throws {
        try transaction {
            guard let row = try notice(noticeID), let latest = try bannerState(noticeID), latest.attemptID == attemptID, latest.state == "unknown" else { return }
            let state = BannerState(attemptID: attemptID, state: error == nil ? "accepted" : "failed", detail: error ?? "macOS accepted banner scheduling. Display is not verified.")
            try append(kind: error == nil ? "banner_accepted" : "banner_failed", noticeID: noticeID, task: row.task, detail: try encode(state), at: time, dedup: "banner-result:" + attemptID)
        }
    }

    /// Legacy files are read, never rewritten. One transaction makes migration
    /// restart-safe; missing click timestamps are explicitly left unknown.
    func migrateLegacy(files: [URL], at time: EventTime) throws {
        guard try metadata("legacy_imported") == nil else { return }
        var notices: [String: Notice] = [:], seen: Set<String> = [], lastRun: Double = 0
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            let archive = try decoder.decode(LegacyArchive.self, from: Data(contentsOf: file))
            for item in archive.notices { notices[item.id] = item; if archive.seen.contains(item.id) { seen.insert(item.id) } else { seen.remove(item.id) } }
            lastRun = max(lastRun, archive.lastRun)
        }
        try transaction {
            for item in notices.values.sorted(by: { ($0.created, $0.id) < ($1.created, $1.id) }) {
                guard try notice(item.id) == nil else { continue }
                let task = TaskIdentity(thread: item.thread, host: item.host, title: item.title)
                try saveTask(task)
                let wasSeen = seen.contains(item.id)
                // Preserve the old Seen status as legacy evidence, not an invented
                // click or proof of a reply. Unresolved seen questions resurface.
                let pending = !wasSeen || (["question", "approval", "input"].contains(item.kind) && !item.resolved)
                let seq = try append(kind: "legacy_import", noticeID: item.id, task: task, detail: "Imported existing notification. \(wasSeen ? "Previously Seen; its click time was not recorded." : "Previously unread.")\n\n" + item.body, at: time, sourceAt: item.created, dedup: "notice:" + item.id)
                try execute("INSERT INTO notices(id,task_key,payload,first_seq,attention,done_reason,legacy_seen,seen) VALUES (?,?,?,?,?,?,?,?)", [.text(item.id), .text(task.key), .text(try encode(item)), .integer(seq), .integer(pending ? 1 : 0), pending ? .null : .text("legacy_seen"), .integer(wasSeen ? 1 : 0), .integer(wasSeen ? 1 : 0)])
            }
            try setMetadata("last_run", String(lastRun))
            try setMetadata("legacy_imported", "1")
        }
    }

    let noticeSelect = "SELECT n.payload,t.payload,n.attention,n.done_reason,n.clicked_at,n.opened_at,n.legacy_seen,n.seen FROM notices n JOIN tasks t ON n.task_key=t.key"
    func noticeRow(_ s: OpaquePointer) throws -> StoredNotice {
        StoredNotice(notice: try decode(Notice.self, text(s, 0)), task: try decode(TaskIdentity.self, text(s, 1)), needsAttention: sqlite3_column_int(s, 2) != 0, doneReason: optionalText(s, 3), clickedAt: optionalNumber(s, 4), openedAt: optionalNumber(s, 5), previouslySeen: sqlite3_column_int(s, 6) != 0, banner: try bannerState(try decode(Notice.self, text(s, 0)).id), seen: sqlite3_column_int(s, 7) != 0)
    }
    func notice(_ id: String) throws -> StoredNotice? { try rows(noticeSelect + " WHERE n.id=?", [.text(id)], noticeRow).first }
    func legacySnapshot(_ query: InboxQuery) throws -> InboxSnapshot {
        var result = InboxSnapshot()
        result.pending = try count("SELECT COUNT(*) FROM notices WHERE attention=1")
        result.total = try count("SELECT COUNT(*) FROM notices")
        result.activityCount = try count("SELECT COUNT(*) FROM activity")
        result.projects = try rows("SELECT t.project_key,COALESCE(t.project_name,CASE WHEN t.project_key='' THEN 'No project' ELSE 'Project name unavailable' END),SUM(n.attention),COUNT(*) FROM notices n JOIN tasks t ON n.task_key=t.key GROUP BY t.project_key ORDER BY SUM(n.attention) DESC,2 COLLATE NOCASE") { ProjectSummary(id: text($0, 0), name: text($0, 1), pending: Int(sqlite3_column_int64($0, 2)), total: Int(sqlite3_column_int64($0, 3))) }
        var whereParts: [String] = [], values: [SQLValue] = []
        if query.section == .history {
            // Old blank identities have unknown provenance, never current membership.
            let historyKey = "CASE WHEN a.project_key<>'' THEN a.project_key WHEN json_extract(a.task_json,'$.projectKnowledge')='none' THEN '' ELSE 'unknown' END"
            result.projects = try rows("SELECT " + historyKey + ",COALESCE(json_extract(a.task_json,'$.projectName'),CASE WHEN json_extract(a.task_json,'$.projectKnowledge')='none' THEN 'No project' ELSE 'Project unknown' END),COUNT(*) FROM activity a GROUP BY 1 ORDER BY 2 COLLATE NOCASE") { ProjectSummary(id: text($0, 0), name: text($0, 1), pending: 0, total: Int(sqlite3_column_int64($0, 2))) }
            if let project = query.project { whereParts.append(historyKey + "=?"); values.append(.text(project)) }
            if let task = query.task { whereParts.append("a.task_key=?"); values.append(.text(task)) }
            if !query.search.isEmpty { whereParts.append("instr(lower(a.detail || ' ' || a.task_json || ' ' || a.kind),lower(?))>0"); values.append(.text(query.search)) }
            let from = " FROM activity a LEFT JOIN tasks t ON a.task_key=t.key" + (whereParts.isEmpty ? "" : " WHERE " + whereParts.joined(separator: " AND "))
            result.matchingCount = try count("SELECT COUNT(*)" + from, values)
            result.activities = try rows("SELECT a.seq,a.notice_id,a.task_json,a.kind,a.detail,a.time_json,a.source_at,t.payload" + from + " ORDER BY a.seq DESC LIMIT ?", values + [.integer(Int64(query.limit))]) { s in
                let task = try decode(TaskIdentity.self, text(s, 2))
                return Activity(id: sqlite3_column_int64(s, 0), noticeID: optionalText(s, 1), task: task, kind: text(s, 3), detail: text(s, 4), time: try decode(EventTime.self, text(s, 5)), sourceAt: optionalNumber(s, 6))
            }
        } else {
            if query.section != .all { whereParts.append("n.attention=?"); values.append(.integer(query.section == .attention ? 1 : 0)) }
            if let project = query.project { whereParts.append("t.project_key=?"); values.append(.text(project)) }
            if !query.search.isEmpty { whereParts.append("instr(lower(n.payload || ' ' || t.title || ' ' || COALESCE(t.project_name,'')),lower(?))>0"); values.append(.text(query.search)) }
            let clause = whereParts.isEmpty ? "" : " WHERE " + whereParts.joined(separator: " AND ")
            result.matchingCount = try count("SELECT COUNT(*) FROM notices n JOIN tasks t ON n.task_key=t.key" + clause, values)
            result.notices = try rows(noticeSelect + clause + " ORDER BY n.first_seq DESC LIMIT ?", values + [.integer(Int64(query.limit))], noticeRow)
        }
        return result
    }
}
