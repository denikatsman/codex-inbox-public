import Foundation
import SQLite3

extension InboxStore {
    func migrateSelectionState() throws {
        try transaction {
            let columns = try rows("PRAGMA table_info(notices)") { text($0, 1) }
            for name in ["seen", "seen_version", "attention_version"] where !columns.contains(name) {
                try execute("ALTER TABLE notices ADD COLUMN " + name + " INTEGER NOT NULL DEFAULT 0")
            }
            let activityColumns = try rows("PRAGMA table_info(activity)") { text($0, 1) }
            if !activityColumns.contains("attempt_id") { try execute("ALTER TABLE activity ADD COLUMN attempt_id TEXT") }
            try execute("CREATE TABLE IF NOT EXISTS task_runtime (task_key TEXT PRIMARY KEY,payload TEXT NOT NULL,observed_at REAL NOT NULL,confirmed INTEGER NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS task_relations (id TEXT PRIMARY KEY,child_key TEXT NOT NULL,payload TEXT NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS relations_child ON task_relations(child_key)")
            try execute("CREATE TABLE IF NOT EXISTS task_visits (task_key TEXT PRIMARY KEY,clicked_at REAL NOT NULL,click_seq INTEGER NOT NULL,attempt_id TEXT,outcome TEXT NOT NULL,detail TEXT NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS visits_recent ON task_visits(click_seq DESC)")
            if try metadata("selection_v1") == nil {
                try execute("UPDATE notices SET seen=CASE WHEN clicked_at IS NOT NULL OR legacy_seen=1 THEN 1 ELSE 0 END")
                try execute("INSERT OR IGNORE INTO task_visits(task_key,clicked_at,click_seq,outcome,detail) SELECT a.task_key,json_extract(a.time_json,'$.at'),a.seq,'unknown','Imported opening request; result unavailable.' FROM activity a WHERE a.kind='open_clicked' AND a.seq=(SELECT MAX(b.seq) FROM activity b WHERE b.task_key=a.task_key AND b.kind='open_clicked')")
                try each("SELECT task_key,click_seq FROM task_visits") { s in
                    let key = text(s, 0), seq = sqlite3_column_int64(s, 1)
                    if let result = try rows("SELECT kind,detail FROM activity WHERE task_key=? AND seq>? AND kind IN ('open_accepted','open_failed') ORDER BY seq DESC LIMIT 1", [.text(key), .integer(seq)], { (text($0, 0), text($0, 1)) }).first {
                        try execute("UPDATE task_visits SET outcome=?,detail=? WHERE task_key=?", [.text(result.0 == "open_accepted" ? "accepted" : "failed"), .text(result.1), .text(key)])
                    }
                    return true
                }
                try setMetadata("selection_v1", "1")
            }
        }
    }

    func applyBatch(_ ids: [String], action: NoticeAction, at time: EventTime) throws -> NoticeUndo {
        try transaction {
            var undo = NoticeUndo(action: action, entries: [])
            for id in Set(ids).sorted() {
                guard let row = try notice(id) else { continue }
                let desired = action == .seen || action == .done
                guard action.changesSeen ? row.seen != desired : row.needsAttention == desired else { continue }
                let kind = action.changesSeen ? (desired ? "marked_seen" : "marked_unseen") : (desired ? "manual_done" : "reopened")
                let seq = try append(kind: kind, noticeID: id, task: row.task, detail: action.rawValue + " · local Inbox action.", at: time)
                undo.entries.append(.init(id: id, version: seq, seen: row.seen, attention: row.needsAttention, reason: row.doneReason, at: time.deviceAt))
                if action.changesSeen {
                    try execute("UPDATE notices SET seen=?,seen_version=? WHERE id=?", [.integer(desired ? 1 : 0), .integer(seq), .text(id)])
                } else {
                    try execute("UPDATE notices SET attention=?,done_reason=?,reopened_seq=?,reopened_at=?,attention_version=? WHERE id=?", [.integer(desired ? 0 : 1), desired ? .text("manual") : .null, .integer(desired ? 0 : seq), desired ? .null : .number(time.deviceAt), .integer(seq), .text(id)])
                }
            }
            return undo
        }
    }

    func undoBatch(_ undo: NoticeUndo, at time: EventTime) throws -> Int {
        try transaction {
            var changed = 0
            for entry in undo.entries {
                guard let row = try notice(entry.id) else { continue }
                let column = undo.action.changesSeen ? "seen_version" : "attention_version"
                let version = try rows("SELECT " + column + " FROM notices WHERE id=?", [.text(entry.id)]) { sqlite3_column_int64($0, 0) }.first
                guard version == entry.version else { continue }
                if !undo.action.changesSeen && entry.attention {
                    var newerReply = false
                    try each("SELECT payload FROM replies WHERE task_key=? AND first_seq>?", [.text(row.task.key), .integer(entry.version)]) { statement in
                        let reply = try decode(Reply.self, text(statement, 0))
                        guard try canonicalReply(reply.id) == reply.id else { return true }
                        let afterAction = reply.created.map { $0 > entry.at } ?? (reply.provenance == "new_action")
                        let afterNotice: Bool
                        if let r = reply.sourceOrdinal, let n = row.notice.sourceOrdinal { afterNotice = r > n }
                        else { afterNotice = reply.created.map { $0 > row.notice.created } ?? (reply.provenance == "new_action") }
                        if afterAction && afterNotice { newerReply = true; return false }
                        return true
                    }
                    if newerReply { continue }
                }
                let seq = try append(kind: "action_undone", noticeID: entry.id, task: row.task, detail: "Undid “" + undo.action.rawValue + "”. Newer changes are preserved.", at: time)
                if undo.action.changesSeen {
                    try execute("UPDATE notices SET seen=?,seen_version=? WHERE id=?", [.integer(entry.seen ? 1 : 0), .integer(seq), .text(entry.id)])
                } else {
                    try execute("UPDATE notices SET attention=?,done_reason=?,reopened_seq=?,reopened_at=?,attention_version=? WHERE id=?", [.integer(entry.attention ? 1 : 0), .optional(entry.reason), .integer(entry.attention ? seq : 0), entry.attention ? .number(time.deviceAt) : .null, .integer(seq), .text(entry.id)])
                }
                changed += 1
            }
            return changed
        }
    }

    func invalidateRuntime() throws { try execute("UPDATE task_runtime SET confirmed=0 WHERE confirmed=1") }

    func enrichOutcome(_ id: String, status: String, at time: EventTime) throws {
        guard ["completed", "interrupted", "failed"].contains(status) else { return }
        try transaction {
            guard var row = try notice(id), row.notice.terminalStatus == nil else { return }
            row.notice.terminalStatus = status
            try execute("UPDATE notices SET payload=? WHERE id=?", [.text(try encode(row.notice)), .text(id)])
            try append(kind: "outcome_observed", noticeID: id, task: row.task, detail: "Original turn outcome recovered: " + status, at: time)
        }
    }

    func observeRuntime(_ value: RuntimeObservation, at time: EventTime) throws {
        try transaction {
            let old = try rows("SELECT payload,confirmed FROM task_runtime WHERE task_key=?", [.text(value.key)]) { (try decode(RuntimeObservation.self, text($0, 0)), sqlite3_column_int($0, 1) != 0) }.first
            if let old {
                // A terminal observation cannot be resurrected by a stale snapshot of the same turn.
                if old.0.turn != nil && old.0.turn == value.turn && ["finished", "failed", "interrupted"].contains(old.0.status) && value.isActive { return }
                if value.source == "parent" && old.0.source != "parent" { return }
                if value.source == "parent", let before = old.0.sourceAt, let next = value.sourceAt, next < before { return }
                if value.source == "history" {
                    if let previous = old.0.sourceOrdinal, let next = value.sourceOrdinal, next < previous { return }
                    if old.1 && old.0.source == "live" && !(old.0.turn == value.turn && !value.isActive && value.status != "idle") { return }
                }
                if old.0 == value && (old.1 || value.source != "live") {
                    if value.source == "live" { try execute("UPDATE task_runtime SET observed_at=? WHERE task_key=?", [.number(time.at), .text(value.key)]) }
                    return
                }
            }
            let task = try self.task(value.key) ?? TaskIdentity(thread: value.thread, host: value.host, title: "Codex task")
            if try self.task(value.key) == nil { try saveTask(task) }
            try execute("INSERT INTO task_runtime VALUES (?,?,?,?) ON CONFLICT(task_key) DO UPDATE SET payload=excluded.payload,observed_at=excluded.observed_at,confirmed=excluded.confirmed", [.text(value.key), .text(try encode(value)), .number(time.at), .integer(value.source == "live" ? 1 : 0)])
            if old?.0.status != value.status || old?.0.turn != value.turn {
                try append(kind: "task_runtime", task: task, detail: try encode(value), at: time, sourceAt: value.sourceAt)
            }
        }
    }

    func observeRelation(_ value: TaskRelation, at time: EventTime) throws {
        guard ["created", "subagent", "delegated"].contains(value.kind), !value.parentThread.isEmpty else { return }
        try transaction {
            let id = try encode([value.host, value.thread, value.kind, value.sourceID])
            let previous = try rows("SELECT payload FROM task_relations WHERE id=?", [.text(id)]) { try decode(TaskRelation.self, text($0, 0)) }.first
            let payload = try encode(value)
            guard previous != value else { return }
            let task = try self.task(value.childKey) ?? TaskIdentity(thread: value.thread, host: value.host, title: "Codex task")
            if try self.task(value.childKey) == nil { try saveTask(task) }
            try execute("INSERT INTO task_relations VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [.text(id), .text(value.childKey), .text(payload)])
            try append(kind: "task_relation", task: task, detail: payload, at: time, sourceAt: value.sourceAt)
        }
    }

    func taskCatalog(now: Double = Date().timeIntervalSince1970) throws -> [String: StoredTask] {
        var catalog: [String: StoredTask] = [:]
        for task in try rows("SELECT payload FROM tasks", [], { try decode(TaskIdentity.self, text($0, 0)) }) {
            catalog[task.key] = StoredTask(task: task, isDot: task.origin == "dot", isSubagent: task.origin == "subagent" || task.threadSource == "subagent")
        }
        let byThread = Dictionary(grouping: catalog.values, by: { $0.task.thread })
        for var relation in try rows("SELECT payload FROM task_relations", [], { try decode(TaskRelation.self, text($0, 0)) }) {
            // Older collectors treated any activity in another chat as a spawn.
            // Keep that original evidence in the journal, but only native parents
            // and explicit spawn records establish ownership in the projection.
            if relation.kind == "subagent" && relation.sourceID.hasPrefix("parent:") { relation.kind = "delegated" }
            catalog[relation.childKey]?.relations.append(relation)
            if relation.kind == "subagent" { catalog[relation.childKey]?.isSubagent = true }
        }
        for key in Array(catalog.keys) {
            guard let row = catalog[key] else { continue }
            let owned = row.relations.filter { $0.kind == "subagent" || $0.kind == "created" }
            let parents = Set(owned.compactMap { relation -> String? in
                if let host = relation.parentHost { return host + "\u{1f}" + relation.parentThread }
                let matches = byThread[relation.parentThread] ?? []
                return matches.count == 1 ? matches[0].id : nil
            })
            if parents.count == 1, let parent = parents.first, parent != key {
                catalog[key]?.parentKey = parent
                catalog[key]?.parentKind = owned.contains { $0.kind == "subagent" } ? "subagent" : "created"
            }
        }
        // Fixed-point propagation only along creation/spawn edges, never message delegation.
        var changed = true
        while changed {
            changed = false
            for key in catalog.keys.sorted() where catalog[key]?.isDot == false {
                if let parent = catalog[key]?.parentKey, catalog[parent]?.isDot == true { catalog[key]?.isDot = true; changed = true }
            }
        }
        for (key, runtime, at, confirmed) in try rows("SELECT task_key,payload,observed_at,confirmed FROM task_runtime", [], { (text($0, 0), try decode(RuntimeObservation.self, text($0, 1)), sqlite3_column_double($0, 2), sqlite3_column_int($0, 3) != 0) }) {
            catalog[key]?.runtime = runtime; catalog[key]?.observedAt = at
            catalog[key]?.confirmed = confirmed && (!runtime.isActive || now - at <= 90)
        }
        for (key, count) in try rows("SELECT task_key,SUM(attention) FROM notices GROUP BY task_key", [], { (text($0, 0), Int(sqlite3_column_int($0, 1))) }) { catalog[key]?.pending = count }
        for (key, at, outcome, detail) in try rows("SELECT task_key,clicked_at,outcome,detail FROM task_visits", [], { (text($0, 0), sqlite3_column_double($0, 1), text($0, 2), text($0, 3)) }) {
            catalog[key]?.lastClickedAt = at; catalog[key]?.openResult = outcome; catalog[key]?.openDetail = detail
        }
        return catalog
    }

    func noticeFilter(_ query: InboxQuery, catalog: [String: StoredTask]) -> (String, [SQLValue]) {
        var clauses: [String] = [], args: [SQLValue] = []
        let state = query.effectiveAttention
        if state != .all { clauses.append("n.attention=?"); args.append(.integer(state == .attention ? 1 : 0)) }
        if query.seen != .all { clauses.append("n.seen=?"); args.append(.integer(query.seen == .seen ? 1 : 0)) }
        if let project = query.project { clauses.append("t.project_key=?"); args.append(.text(project)) }
        if let task = query.task { clauses.append("n.task_key=?"); args.append(.text(task)) }
        let kinds: [InboxSection: String] = [.questions: "question", .approvals: "approval", .input: "input", .finished: "completion"]
        if let kind = kinds[query.section] { clauses.append("json_extract(n.payload,'$.kind')=?"); args.append(.text(kind)) }
        if query.section == .interrupted { clauses.append("json_extract(n.payload,'$.terminalStatus')='interrupted'") }
        if query.section == .failed { clauses.append("json_extract(n.payload,'$.kind')='error' AND COALESCE(json_extract(n.payload,'$.terminalStatus'),'unknown')<>'interrupted'") }
        if query.section == .dot || query.section == .subagents {
            let keys = catalog.values.filter { query.section == .dot ? $0.isDot : $0.isSubagent }.map(\.id).sorted()
            clauses.append(keys.isEmpty ? "0" : "n.task_key IN (" + keys.map { _ in "?" }.joined(separator: ",") + ")")
            args += keys.map(SQLValue.text)
        }
        if !query.search.isEmpty { clauses.append("instr(lower(n.payload || ' ' || t.payload),lower(?))>0"); args.append(.text(query.search)) }
        return (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND "), args)
    }

    func matchingNoticeIDs(_ query: InboxQuery) throws -> [String] {
        let (clause, args) = noticeFilter(query, catalog: try taskCatalog())
        return try rows("SELECT n.id FROM notices n JOIN tasks t ON n.task_key=t.key" + clause + " ORDER BY n.first_seq DESC", args) { text($0, 0) }
    }
    func selectedNotices(_ ids: [String]) throws -> [StoredNotice] {
        // Bounded SQL parameter batches; payloads are fetched only for explicit copy actions.
        var result: [StoredNotice] = []
        for offset in stride(from: 0, to: ids.count, by: 400) {
            let slice = Array(ids[offset..<min(offset + 400, ids.count)])
            result += try rows(noticeSelect + " WHERE n.id IN (" + slice.map { _ in "?" }.joined(separator: ",") + ") ORDER BY n.first_seq DESC", slice.map(SQLValue.text), noticeRow)
        }
        return result
    }

    func matchingTasks(_ query: InboxQuery, catalog: [String: StoredTask]) -> [StoredTask] {
        var result = catalog.values.filter { row in
            if let project = query.project, row.task.projectKey != project { return false }
            if let task = query.task, row.id != task { return false }
            if !query.search.isEmpty && !(row.task.displayTitle + " " + (row.task.projectName ?? "") + " " + (row.originLabel ?? "") + " " + row.status).localizedCaseInsensitiveContains(query.search) { return false }
            switch query.section {
            case .running: return row.isRunning
            case .unconfirmed: return row.runtime?.isActive == true && row.isUnconfirmed
            case .recent: return row.lastClickedAt != nil
            case .dot: return row.isDot
            case .subagents: return row.isSubagent
            default: return false
            }
        }
        result.sort {
            if query.section == .recent { return ($0.lastClickedAt ?? 0, $0.id) > ($1.lastClickedAt ?? 0, $1.id) }
            let left = $0.runtime?.isActive == true ? 1 : 0, right = $1.runtime?.isActive == true ? 1 : 0
            return (left, $0.observedAt ?? 0, $0.id) > (right, $1.observedAt ?? 0, $1.id)
        }
        return result
    }

    func snapshot(_ query: InboxQuery, now: Double = Date().timeIntervalSince1970) throws -> InboxSnapshot {
        let catalog = try taskCatalog(now: now)
        var result = query.section == .history ? try legacySnapshot(query) : InboxSnapshot()
        result.taskCatalog = catalog
        result.runningProjects = RunningProject.groups(in: catalog)
        result.pending = try count("SELECT COUNT(*) FROM notices WHERE attention=1")
        result.total = try count("SELECT COUNT(*) FROM notices")
        result.activityCount = try count("SELECT COUNT(*) FROM activity")
        result.recentActionable = try rows(noticeSelect + " WHERE n.attention=1 ORDER BY n.first_seq DESC LIMIT 3", [], noticeRow).map { row in
            row.contextualized(in: catalog)
        }
        for row in catalog.values where row.runtime?.isActive == true {
            if row.isUnconfirmed { result.unconfirmed += 1 }
            else if row.runtime?.status == "working" { result.working += 1 }
            else { result.waiting += 1 }
        }
        if query.section != .history {
            result.projects = try rows("SELECT t.project_key,COALESCE(t.project_name,'No project'),COALESCE(SUM(n.attention),0),COUNT(DISTINCT t.key) FROM tasks t LEFT JOIN notices n ON n.task_key=t.key GROUP BY t.project_key ORDER BY 2 COLLATE NOCASE") { ProjectSummary(id: text($0, 0), name: text($0, 1), pending: Int(sqlite3_column_int($0, 2)), total: Int(sqlite3_column_int($0, 3))) }
        }
        for section in InboxSection.allCases where section != .history {
            var filter = query; filter.section = section; filter.task = nil; filter.showNotifications = false
            if filter.isTaskView { result.sectionCounts[section] = matchingTasks(filter, catalog: catalog).count }
            else {
                let (clause, args) = noticeFilter(filter, catalog: catalog)
                result.sectionCounts[section] = try count("SELECT COUNT(*) FROM notices n JOIN tasks t ON n.task_key=t.key" + clause, args)
            }
        }
        if query.isTaskView {
            let matches = matchingTasks(query, catalog: catalog)
            result.matchingCount = matches.count
            var visible = Array(matches.prefix(query.limit))
            if query.section != .recent {
                var included = Set(visible.map(\.id))
                for row in Array(visible) {
                    var next = row.parentKey, visited: Set<String> = [row.id]
                    while let key = next, visited.insert(key).inserted, let parent = catalog[key] {
                        if included.insert(key).inserted { var context = parent; context.contextOnly = true; visible.append(context) }
                        next = parent.parentKey
                    }
                }
            }
            result.taskRows = visible
        } else if query.section != .history {
            let (clause, args) = noticeFilter(query, catalog: catalog)
            result.matchingIDs = try rows("SELECT n.id FROM notices n JOIN tasks t ON n.task_key=t.key" + clause + " ORDER BY n.first_seq DESC", args) { text($0, 0) }
            result.matchingCount = result.matchingIDs.count
            result.notices = try rows(noticeSelect + clause + " ORDER BY n.first_seq DESC LIMIT ?", args + [.integer(Int64(query.limit))], noticeRow).map { row in
                row.contextualized(in: catalog)
            }
        }
        return result
    }
}
