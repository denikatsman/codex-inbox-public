import AppKit
import SwiftUI

extension Color {
    static let inboxAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.05, green: 0.79, blue: 0.84, alpha: 1)
            : NSColor(calibratedRed: 0, green: 0.39, blue: 0.43, alpha: 1)
    })
    static let inboxSecondary = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(calibratedWhite: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.68 : 0.40, alpha: 1)
    })
}

extension Notice {
    var symbol: String {
        switch kind {
        case "question": return "questionmark.bubble.fill"
        case "approval": return "hand.raised.fill"
        case "input": return "rectangle.and.pencil.and.ellipsis"
        case "error": return terminalStatus == "interrupted" ? "pause.circle.fill" : "exclamationmark.triangle.fill"
        case "test": return "bell.badge.fill"
        default: return "checkmark.circle.fill"
        }
    }
    var label: String {
        switch kind {
        case "question": return "Question"
        case "approval": return "Approval"
        case "input": return "Input needed"
        case "error": return terminalStatus == "interrupted" ? "Interrupted" : terminalStatus == "failed" ? "Failed" : "Problem · outcome unknown"
        case "test": return "Test alert"
        default: return "Finished"
        }
    }
    var tint: Color {
        switch kind {
        case "question", "input": return .blue
        case "approval": return .orange
        case "error": return terminalStatus == "interrupted" ? .orange : .red
        case "test": return .purple
        default: return .inboxAccent
        }
    }
}

enum DisplayTime {
    static let exact: DateFormatter = {
        let value = DateFormatter(); value.dateFormat = "d MMM yyyy, HH:mm:ss ZZZZ"; value.timeZone = .autoupdatingCurrent; return value
    }()
    static func full(_ value: Double) -> String { exact.string(from: Date(timeIntervalSince1970: value)) }
    static func ago(_ value: Double, now: Double) -> String {
        let seconds = max(0, Int(now - value))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86400 { return "\(seconds / 3600) hr ago" }
        return "\(seconds / 86400) days ago"
    }
}

struct ActivityRow: View {
    let item: Activity
    let open: () -> Void
    let history: () -> Void
    @State private var expanded = false
    private var detail: String {
        if item.kind.hasPrefix("banner_"), let state = try? JSONDecoder().decode(BannerState.self, from: Data(item.detail.utf8)) { return state.detail }
        if item.kind == "task_runtime", let value = try? JSONDecoder().decode(RuntimeObservation.self, from: Data(item.detail.utf8)) {
            return StoredTask(task: item.task, runtime: value, confirmed: value.source == "live").status + " · " + (value.source == "live" ? "live observation" : "retained source record")
        }
        if item.kind == "task_relation", let value = try? JSONDecoder().decode(TaskRelation.self, from: Data(item.detail.utf8)) {
            let kind = value.kind == "created" ? "Created by" : value.kind == "subagent" ? "Subagent of" : "Delegated by"
            return kind + " task " + value.parentThread + (value.parentHost.map { " · " + $0 } ?? " · host not supplied")
        }
        return item.detail
    }
    private var label: String {
        switch item.kind {
        case "banner_attempt": return "Banner requested"
        case "banner_accepted": return "Banner scheduling accepted"
        case "banner_failed": return "Banner failed"
        case "notification": return "Notification arrived"
        case "notification_updated": return "Notification updated"
        case "imported": return "Notification recovered from history"
        case "legacy_import": return "Existing notification preserved"
        case "legacy_title_corrected": return "Historical title corrected"
        case "open_clicked": return "Clicked to open"
        case "open_accepted": return "Task link accepted by macOS"
        case "open_failed": return "Task could not be opened"
        case "message_sent": return "Message sent in task"
        case "done_after_reply": return "Done · message sent afterward"
        case "manual_done": return "Marked done"
        case "reopened": return "Returned to Needs attention"
        case "answer_recorded": return "Answer recorded"
        case "request_ended": return "Request ended · outcome unavailable"
        case "task_updated": return "Task details changed"
        case "marked_seen": return "Marked seen"
        case "marked_unseen": return "Marked unseen"
        case "action_undone": return "Action undone"
        case "task_runtime": return "Task status changed"
        case "task_relation": return "Task relationship observed"
        case "outcome_observed": return "Turn outcome recovered"
        default: return item.kind
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 5) {
                Circle().fill(item.kind == "open_failed" ? .orange : .inboxAccent).frame(width: 7, height: 7)
                Rectangle().fill(.primary.opacity(0.07)).frame(width: 1)
            }.frame(width: 10).padding(.top, 7)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(label).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(Date(timeIntervalSince1970: item.time.at), format: .dateTime.month(.abbreviated).day().hour().minute().second()).font(.system(size: 10)).foregroundStyle(Color.inboxSecondary).help(DisplayTime.full(item.time.at))
                }
                HStack(spacing: 7) {
                    Button(item.task.displayTitle, action: history).buttonStyle(.plain).lineLimit(1).help("Show this task’s complete activity chain")
                    if let project = item.task.projectName { Text("· " + project).lineLimit(1) }
                }.font(.system(size: 11)).foregroundStyle(Color.inboxSecondary)
                Text(detail).font(.system(size: 12)).foregroundStyle(Color.inboxSecondary).lineSpacing(3).lineLimit(expanded ? nil : 2).textSelection(.enabled)
                HStack {
                    Button(expanded ? "Less" : "Details") { expanded.toggle() }.buttonStyle(.plain)
                    Spacer()
                    if TaskLaunch(thread: item.task.thread, host: item.task.host) != nil {
                        Button(action: open) { Label("Open task", systemImage: "arrow.up.right") }.buttonStyle(.plain)
                    }
                }.font(.system(size: 10)).foregroundStyle(Color.inboxAccent)
                if expanded {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recorded: " + DisplayTime.full(item.time.at))
                        if let source = item.sourceAt { Text("Codex / original record time: " + DisplayTime.full(source)) }
                        Text(item.time.quality + " · event #\(item.id)")
                        if abs(item.time.deviceAt - item.time.at) > 2 { Text("Mac clock at capture: " + DisplayTime.full(item.time.deviceAt)) }
                    }.font(.system(size: 10)).foregroundStyle(Color.inboxSecondary).textSelection(.enabled)
                }
            }.padding(.bottom, 22).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
