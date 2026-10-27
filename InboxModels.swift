import Foundation

enum InboxAlertSound: String, CaseIterable, Identifiable {
    case glass = "Glass", ping = "Ping", tink = "Tink", pop = "Pop"
    case bottle = "Bottle", purr = "Purr", basso = "Basso", blow = "Blow"
    case frog = "Frog", funk = "Funk", hero = "Hero", morse = "Morse"
    case sosumi = "Sosumi", submarine = "Submarine"
    var id: String { rawValue }
}

struct Notice: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var thread: String
    var host: String
    var kind: String
    var title: String
    var body: String
    var created: Double
    var resolved: Bool
    var historical: Bool?
    var deadline: Double?
    var estimated: Bool?
    var timerUnavailable: Bool?
    var resolution: String?
    var sourceOrdinal: Int64?
    var timeSource: String?
    var turn: String?
    var questionID: String?
    var identityAmbiguous: Bool?
    var terminalStatus: String?
    var url: URL? { TaskLaunch(thread: thread, host: host)?.url }
}

struct LegacyArchive: Codable {
    var notices: [Notice]
    var seen: Set<String>
    var lastRun: Double
}

struct TaskIdentity: Codable, Equatable, Sendable {
    var thread: String
    var host: String = "local"
    var title: String
    var projectID: String?
    var projectName: String?
    var projectKnowledge: String?
    var origin: String?
    var originator: String?
    var threadSource: String?
    var agentNickname: String?
    var agentRole: String?
    var displayTitle: String {
        if !title.isEmpty && title != "Codex task" && title != thread { return title }
        if let nickname = agentNickname, !nickname.isEmpty { return nickname }
        if origin == "dot" { return "Dot" }
        return "Untitled task · " + String(thread.prefix(8))
    }
    var historyProjectKey: String { projectID != nil ? projectKey : (projectKnowledge == "none" ? "" : "unknown") }
    var key: String { host + "\u{1f}" + thread }
    var projectKey: String { projectID.map { host + "\u{1f}" + $0 } ?? "" }
}

struct Reply: Codable, Equatable, Sendable {
    var id: String
    var thread: String
    var host: String
    var body: String
    var created: Double?
    var sourceOrdinal: Int64?
    var live: Bool
    var provenance: String?
    var aliases: [String]?
    var answeredQuestionIDs: [String]?
}

struct EventTime: Codable, Equatable, Sendable {
    var at: Double
    var deviceAt: Double
    var elapsed: Double
    var session: String
    var quality: String
}

struct StoredNotice: Identifiable, Equatable, Sendable {
    var notice: Notice
    var task: TaskIdentity
    var needsAttention: Bool
    var doneReason: String?
    var clickedAt: Double?
    var openedAt: Double?
    var previouslySeen: Bool
    var banner: BannerState? = nil
    var seen = false
    var originLabel: String? = nil
    var parentTask: TaskIdentity? = nil
    var parentKind: String? = nil
    var id: String { notice.id }
    var parentLabel: String? {
        parentTask.map { (parentKind == "subagent" ? "Subagent of " : "Created by ") + $0.displayTitle }
    }
    func contextualized(in catalog: [String: StoredTask]) -> Self {
        var row = self
        let context = catalog[task.key]
        row.originLabel = context?.originLabel
        row.parentTask = context?.parentKey.flatMap { catalog[$0]?.task }
        row.parentKind = context?.parentKind
        return row
    }
}

struct Activity: Identifiable, Sendable {
    var id: Int64
    var noticeID: String?
    var task: TaskIdentity
    var kind: String
    var detail: String
    var time: EventTime
    var sourceAt: Double?
}

struct ProjectSummary: Identifiable, Sendable {
    var id: String
    var name: String
    var pending: Int
    var total: Int
}

enum InboxSection: String, CaseIterable, Sendable {
    case attention = "Needs attention", done = "Done", all = "All", history = "History"
    case questions = "Questions", approvals = "Approvals", input = "Tool input"
    case finished = "Finished", interrupted = "Interrupted", failed = "Failed"
    case running = "Running", unconfirmed = "Unconfirmed", recent = "Recently opened", dot = "Dot", subagents = "Subagents"
    static let notifications: [Self] = [.attention, .questions, .approvals, .input, .finished, .interrupted, .failed, .done, .all]
    static let taskViews: [Self] = [.running, .unconfirmed, .recent, .dot, .subagents]
    var symbol: String {
        switch self {
        case .attention: return "tray"
        case .done: return "checkmark.circle"
        case .all: return "square.stack"
        case .history: return "clock.arrow.circlepath"
        case .questions: return "questionmark.bubble"
        case .approvals: return "hand.raised"
        case .input: return "rectangle.and.pencil.and.ellipsis"
        case .finished: return "checkmark.seal"
        case .interrupted: return "pause.circle"
        case .failed: return "exclamationmark.triangle"
        case .running: return "waveform.path"
        case .unconfirmed: return "questionmark.circle"
        case .recent: return "arrow.up.right.square"
        case .dot: return "circle.inset.filled"
        case .subagents: return "point.3.connected.trianglepath.dotted"
        }
    }
}

enum AttentionFilter: String, CaseIterable, Sendable { case attention = "Needs attention", done = "Done", all = "All" }
enum SeenFilter: String, CaseIterable, Sendable { case all = "Any seen state", unseen = "Unseen", seen = "Seen" }

struct InboxQuery: Equatable, Sendable {
    var section: InboxSection = .attention
    var project: String?
    var task: String?
    var search = ""
    var limit = 100
    var attention: AttentionFilter = .attention
    var seen: SeenFilter = .all
    var showNotifications = false
    var isTaskView: Bool { [.running, .unconfirmed, .recent].contains(section) || ([.dot, .subagents].contains(section) && !showNotifications) }
    var effectiveAttention: AttentionFilter {
        section == .attention ? .attention : section == .done ? .done : section == .all ? .all : attention
    }
    var selectionScope: Self { var copy = self; copy.limit = 0; return copy }
}

struct InboxSnapshot: Sendable {
    var notices: [StoredNotice] = []
    var recentActionable: [StoredNotice] = []
    var activities: [Activity] = []
    var projects: [ProjectSummary] = []
    var pending = 0
    var total = 0
    var activityCount = 0
    var matchingCount = 0
    var matchingIDs: [String] = []
    var taskRows: [StoredTask] = []
    var taskCatalog: [String: StoredTask] = [:]
    var runningProjects: [RunningProject] = []
    var sectionCounts: [InboxSection: Int] = [:]
    var working = 0
    var waiting = 0
    var unconfirmed = 0
}

struct RuntimeObservation: Codable, Equatable, Sendable {
    var thread: String
    var host: String
    var status: String
    var turn: String?
    var sourceOrdinal: Int64?
    var sourceAt: Double?
    var source: String
    var key: String { host + "\u{1f}" + thread }
    var isActive: Bool { ["working", "waiting_user", "waiting_agents"].contains(status) }
}

struct TaskRelation: Codable, Equatable, Sendable {
    var thread: String
    var host: String
    var parentThread: String
    var parentHost: String?
    var kind: String
    var sourceID: String
    var sourceAt: Double?
    var childKey: String { host + "\u{1f}" + thread }
}

struct StoredTask: Identifiable, Sendable {
    var task: TaskIdentity
    var runtime: RuntimeObservation?
    var observedAt: Double?
    var confirmed = false
    var parentKey: String?
    var parentKind: String?
    var relations: [TaskRelation] = []
    var isDot = false
    var isSubagent = false
    var pending = 0
    var lastClickedAt: Double?
    var openResult: String?
    var openDetail: String?
    var contextOnly = false
    var id: String { task.key }
    var isRunning: Bool { runtime?.isActive == true && !isUnconfirmed }
    var isUnconfirmed: Bool {
        guard let runtime else { return true }
        return !["working", "waiting_user", "waiting_agents", "idle", "finished", "interrupted", "failed"].contains(runtime.status) || (runtime.isActive && !confirmed)
    }
    var status: String {
        guard let runtime else { return "Status unavailable" }
        if isUnconfirmed { return "Unconfirmed" }
        switch runtime.status {
        case "working": return "Working"
        case "waiting_user": return "Waiting for you"
        case "waiting_agents": return "Waiting for agents"
        case "finished": return "Finished"
        case "interrupted": return "Interrupted"
        case "failed": return "Failed"
        case "idle": return "Idle"
        default: return "Unconfirmed"
        }
    }
    var originLabel: String? {
        if task.origin == "dot" { return "Dot" }
        if isDot { return isSubagent ? "Dot · Subagent" : "Created by Dot" }
        if isSubagent { return "Subagent" }
        if parentKind == "created" || task.threadSource == "agent_created_thread" { return "Agent-created" }
        return nil
    }
}

struct RunningProject: Identifiable, Sendable {
    var id: String
    var name: String
    var tasks: [StoredTask]

    static func groups(in catalog: [String: StoredTask]) -> [Self] {
        Dictionary(grouping: catalog.values.filter(\.isRunning), by: { $0.task.projectKey }).map { key, rows in
            let names = rows.compactMap(\.task.projectName).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.sorted()
            return Self(id: key, name: key.isEmpty ? "No project" : names.first ?? "Unnamed project", tasks: rows.sorted {
                let order = $0.task.displayTitle.localizedStandardCompare($1.task.displayTitle)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            })
        }.sorted {
            if $0.id.isEmpty != $1.id.isEmpty { return !$0.id.isEmpty }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

enum NoticeAction: String, Sendable {
    case seen = "Mark seen", unseen = "Mark unseen", done = "Mark done", reopen = "Reopen"
    var changesSeen: Bool { self == .seen || self == .unseen }
}
struct NoticeUndo: Sendable {
    struct Entry: Sendable {
        var id: String
        var version: Int64
        var seen: Bool
        var attention: Bool
        var reason: String?
        var at: Double
    }
    var action: NoticeAction
    var entries: [Entry]
}

struct RequestObservation: Codable, Sendable {
    var identity: String
    var opaque: Bool
    var kind: String
    var body: String
    var deadline: Double?
    var estimated: Bool?
    var timerUnavailable: Bool?
}
struct RequestOccurrence: Codable {
    var id: String
    var present: Bool
}
struct BannerState: Codable, Equatable, Sendable {
    var attemptID: String
    var state: String
    var detail: String
}
