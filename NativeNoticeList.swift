import AppKit
import SwiftUI

enum NoticeListLayout: String, CaseIterable {
    case messages = "Messages", byChat = "Alerts", timeline = "Updates", map = "Map"
}

struct NoticeProjectHeader: Equatable {
    var key: String
    var name: String
    var chatCount: Int
    var subagentCount = 0
}

struct NoticeConversationBox: Equatable {
    var key: String
    var depth: Int
    var isSubagent: Bool
    var left: CGFloat { 24 + CGFloat(depth) * 28 }
    var rightInset: CGFloat { 24 + CGFloat(depth) * 12 }
}

struct NoticeContentHeader: Equatable {
    var key: String
    var title: String
    var detail: String
    var isChildren = false
}

struct NoticeListEntry: Equatable {
    var notice: StoredNotice?
    var group: TaskIdentity?
    var project: NoticeProjectHeader?
    var content: NoticeContentHeader?
    var conversationEnd: String?
    var projectKey = ""
    var endsProject = false
    var count = 0
    var ownCount = 0
    var childChatCount = 0
    var childSubagentCount = 0
    var memberIDs: [String] = []
    var depth = 0
    var branches: [Bool] = []
    var startsChildren = false
    var contextOnly = false
    var boxes: [NoticeConversationBox] = []
    var timelineActor: String?
    var actorIsSubagent = false
    var id: String {
        if let notice { return "notice:" + notice.id }
        if let group { return "group:" + projectKey + "\u{1d}" + group.key }
        if let content { return "content:" + projectKey + "\u{1d}" + content.key }
        if let conversationEnd { return "chat-end:" + projectKey + "\u{1d}" + conversationEnd }
        return (endsProject ? "project-end:" : "project:") + projectKey
    }
}

enum NoticeGrouping {
    /// Project boxes contain chat trees built only from evidenced ancestry.
    /// Context headers never import nonmatching alerts or change project identity.
    static func entries(_ notices: [StoredNotice], catalog: [String: StoredTask], collapsed: Set<String> = [], layout: NoticeListLayout = .byChat) -> [NoticeListEntry] {
        var paths: [String: [TaskIdentity]] = [:]
        for notice in notices where paths[notice.task.key] == nil {
            var path: [TaskIdentity] = [], visited: Set<String> = [notice.task.key]
            var next = catalog[notice.task.key]?.parentKey
            while let key = next, let parent = catalog[key] {
                guard visited.insert(key).inserted else { path = []; break }
                path.append(parent.task); next = parent.parentKey
            }
            paths[notice.task.key] = path
        }
        var projectKeys: [String] = [], seenProjects: Set<String> = []
        for notice in notices {
            if seenProjects.insert(notice.task.projectKey).inserted { projectKeys.append(notice.task.projectKey) }
        }
        let projects = Dictionary(grouping: notices, by: { $0.task.projectKey })
        var result: [NoticeListEntry] = []
        for projectKey in projectKeys {
            let members = projects[projectKey] ?? []
            let own = Dictionary(grouping: members, by: { $0.task.key })
            let name = projectKey.isEmpty ? "No project" : members.compactMap(\.task.projectName).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "Unnamed project"
            let subagentCount = own.keys.filter { catalog[$0]?.isSubagent == true }.count
            result.append(NoticeListEntry(project: NoticeProjectHeader(key: projectKey, name: name, chatCount: own.count - subagentCount, subagentCount: subagentCount), projectKey: projectKey, count: members.count, memberIDs: members.map(\.id)))

            var tasks: [String: TaskIdentity] = [:], children: [String: [String]] = [:], descendantIDs: [String: [String]] = [:]
            var roots: [String] = [], seenRoots: Set<String> = [], edges: Set<String> = []
            // First appearance keeps projects and sibling chats ordered by their
            // newest loaded alert; each chat retains its own pinned arrival order.
            for notice in members {
                let route = Array((paths[notice.task.key] ?? []).reversed()) + [notice.task]
                if let root = route.first, seenRoots.insert(root.key).inserted { roots.append(root.key) }
                for (index, task) in route.enumerated() {
                    tasks[task.key] = task
                    descendantIDs[task.key, default: []].append(notice.id)
                    if index > 0 {
                        let parent = route[index - 1].key
                        if edges.insert(parent + "\u{1d}" + task.key).inserted { children[parent, default: []].append(task.key) }
                    }
                }
            }
            if layout == .timeline {
                let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
                let order = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($0.element.id, $0.offset) })
                for root in roots {
                    guard let task = tasks[root] else { continue }
                    let ids = descendantIDs[root] ?? [], nested = children[root] ?? []
                    let agents = nested.filter { catalog[$0]?.isSubagent == true }.count
                    let box = NoticeConversationBox(key: root, depth: 0, isSubagent: catalog[root]?.isSubagent == true)
                    result.append(NoticeListEntry(group: task, projectKey: projectKey, count: ids.count, ownCount: own[root]?.count ?? 0, childChatCount: nested.count - agents, childSubagentCount: agents, memberIDs: ids, contextOnly: own[root]?.isEmpty != false, boxes: [box]))
                    if !collapsed.contains(root) {
                        let section = NoticeContentHeader(key: root + ":timeline", title: "TIMELINE · \(ids.count) UPDATES SHOWN", detail: "This conversation and its children · Newest recorded time first · Unknown times last")
                        result.append(NoticeListEntry(content: section, projectKey: projectKey, boxes: [box]))
                        let updates = ids.compactMap { byID[$0] }.sorted {
                            let leftKnown = $0.notice.timeSource != "unknown", rightKnown = $1.notice.timeSource != "unknown"
                            if leftKnown != rightKnown { return leftKnown }
                            if leftKnown && $0.notice.created != $1.notice.created { return $0.notice.created > $1.notice.created }
                            return (order[$0.id] ?? 0) < (order[$1.id] ?? 0)
                        }
                        for update in updates {
                            let agent = catalog[update.task.key]?.isSubagent == true
                            let actor = update.task.key == root && !agent ? "MAIN CHAT" : (agent ? "SUBAGENT · " : "CHILD CHAT · ") + update.task.displayTitle
                            result.append(NoticeListEntry(notice: update, projectKey: projectKey, depth: 1, boxes: [box], timelineActor: actor, actorIsSubagent: agent))
                        }
                    }
                    result.append(NoticeListEntry(conversationEnd: root, projectKey: projectKey, boxes: [box]))
                }
                result.append(NoticeListEntry(projectKey: projectKey, endsProject: true))
                continue
            }
            var visited: Set<String> = []
            func walk(_ key: String, branches: [Bool], ancestors: [NoticeConversationBox]) {
                guard visited.insert(key).inserted, let task = tasks[key] else { return }
                let alerts = own[key] ?? [], nested = children[key] ?? []
                let ids = descendantIDs[key] ?? []
                let expanded = !collapsed.contains(key)
                let agents = nested.filter { catalog[$0]?.isSubagent == true }.count
                let box = NoticeConversationBox(key: key, depth: branches.count, isSubagent: catalog[key]?.isSubagent == true)
                let boxes = ancestors + [box]
                result.append(NoticeListEntry(group: task, projectKey: projectKey, count: ids.count, ownCount: alerts.count, childChatCount: nested.count - agents, childSubagentCount: agents, memberIDs: ids, depth: branches.count, branches: branches, startsChildren: expanded && !nested.isEmpty, contextOnly: alerts.isEmpty, boxes: boxes))
                if expanded {
                    let guides = branches + [!nested.isEmpty]
                    if !alerts.isEmpty {
                        let title = (box.isSubagent ? "SUBAGENT UPDATES" : "CHAT UPDATES") + " · \(alerts.count)"
                        let section = NoticeContentHeader(key: key + ":updates", title: title, detail: "Final replies and requests · Open the chat for every message")
                        result.append(NoticeListEntry(content: section, projectKey: projectKey, depth: guides.count, branches: guides, boxes: boxes))
                        for alert in alerts {
                            result.append(NoticeListEntry(notice: alert, projectKey: projectKey, depth: guides.count, branches: guides, boxes: boxes))
                        }
                    }
                    if !nested.isEmpty {
                        let title = agents == nested.count ? "SUBAGENTS" : agents == 0 ? "CHILD CHATS" : "SUBAGENTS & CHILD CHATS"
                        let detail = agents == nested.count ? "Each subagent has its own conversation and updates below" : "Separate conversations created by this chat"
                        let section = NoticeContentHeader(key: key + ":children", title: title + " · \(nested.count)", detail: detail, isChildren: true)
                        result.append(NoticeListEntry(content: section, projectKey: projectKey, depth: guides.count, branches: guides, boxes: boxes))
                        for (index, child) in nested.enumerated() {
                            walk(child, branches: branches + [index < nested.count - 1], ancestors: boxes)
                        }
                    }
                }
                result.append(NoticeListEntry(conversationEnd: key, projectKey: projectKey, depth: branches.count, branches: branches, boxes: boxes))
            }
            for root in roots { walk(root, branches: [], ancestors: []) }
            result.append(NoticeListEntry(projectKey: projectKey, endsProject: true))
        }
        return result
    }
}

@MainActor final class NoticeProjectCell: NSTableCellView {
    let glyph = NSImageView()
    let badge = NSTextField(labelWithString: "PROJECT")
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        glyph.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        glyph.contentTintColor = NSColor(Color.inboxAccent)
        badge.font = .systemFont(ofSize: 9, weight: .bold); badge.textColor = NSColor(Color.inboxAccent)
        title.font = .systemFont(ofSize: 15, weight: .bold); title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [badge, title]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 3
        for view in [glyph, text, detail] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26), glyph.centerYAnchor.constraint(equalTo: centerYAnchor), glyph.widthAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 9), text.centerYAnchor.constraint(equalTo: centerYAnchor), title.widthAnchor.constraint(equalTo: text.widthAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 14), detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26), detail.centerYAnchor.constraint(equalTo: title.centerYAnchor)
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ project: NoticeProjectHeader, count: Int, selected: Int) {
        badge.stringValue = project.key.isEmpty ? "UNASSIGNED" : "PROJECT"
        title.stringValue = project.name; title.toolTip = project.name
        var parts: [String] = []
        if project.chatCount > 0 { parts.append("\(project.chatCount) " + (project.chatCount == 1 ? "chat" : "chats")) }
        if project.subagentCount > 0 { parts.append("\(project.subagentCount) " + (project.subagentCount == 1 ? "subagent" : "subagents")) }
        parts.append("\(count) updates shown")
        if selected > 0 { parts.append("\(selected) selected") }
        detail.stringValue = parts.joined(separator: " · ")
        detail.toolTip = "Counts cover notifications on the loaded page."
        setAccessibilityLabel(project.name + ". " + detail.stringValue)
    }
}

@MainActor final class NoticeContentCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 10, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, detail]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
        text.translatesAutoresizingMaskIntoConstraints = false; addSubview(text)
        leading = text.leadingAnchor.constraint(equalTo: leadingAnchor)
        trailing = text.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([leading, trailing, text.centerYAnchor.constraint(equalTo: centerYAnchor), title.widthAnchor.constraint(equalTo: text.widthAnchor), detail.widthAnchor.constraint(equalTo: text.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ section: NoticeContentHeader, box: NoticeConversationBox) {
        leading.constant = box.left + 30; trailing.constant = -box.rightInset - 12
        title.stringValue = section.title; title.textColor = section.isChildren || box.isSubagent ? .systemPurple : .systemBlue
        detail.stringValue = section.detail; detail.toolTip = section.detail
        setAccessibilityLabel(section.title + ". " + section.detail)
    }
}

@MainActor final class NoticeGroupCell: NSTableCellView {
    let disclosure = NSButton(title: "", target: nil, action: nil)
    let badge = NSTextField(labelWithString: "")
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let openButton = NSButton(title: "Open parent", target: nil, action: nil)
    let mapButton = NSButton(title: "Map", target: nil, action: nil)
    var toggle: (() -> Void)?
    var open: (() -> Void)?
    var showMap: (() -> Void)?
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    override init(frame: NSRect) {
        super.init(frame: frame)
        disclosure.isBordered = false; disclosure.target = self; disclosure.action = #selector(toggled)
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        title.font = .systemFont(ofSize: 13, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingTail
        openButton.bezelStyle = .rounded; openButton.controlSize = .small
        openButton.target = self; openButton.action = #selector(opened)
        mapButton.bezelStyle = .rounded; mapButton.controlSize = .small
        mapButton.target = self; mapButton.action = #selector(mapped); mapButton.toolTip = "Show this chat and its subagents using saved turns and messages"
        let text = NSStackView(views: [badge, title, detail]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
        for view in [disclosure, text, mapButton, openButton] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        leading = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36)
        trailing = openButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36)
        NSLayoutConstraint.activate([
            leading, disclosure.centerYAnchor.constraint(equalTo: centerYAnchor), disclosure.widthAnchor.constraint(equalToConstant: 20),
            text.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 9), text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(equalTo: mapButton.leadingAnchor, constant: -12), title.widthAnchor.constraint(equalTo: text.widthAnchor), detail.widthAnchor.constraint(equalTo: text.widthAnchor),
            mapButton.widthAnchor.constraint(equalToConstant: 44), mapButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -8), mapButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            openButton.widthAnchor.constraint(equalToConstant: 96), trailing, openButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggled() { toggle?() }
    @objc private func opened() { open?() }
    @objc private func mapped() { showMap?() }
    func configure(_ task: TaskIdentity, count: Int, ownCount: Int, childChatCount: Int, childSubagentCount: Int, selected: Int, collapsed: Bool, opening: Bool, depth: Int, kind: String, contextOnly: Bool, projectKey: String) {
        leading.constant = 36 + CGFloat(depth) * 28; trailing.constant = -36 - CGFloat(depth) * 12
        let agent = kind == "Subagent"
        badge.stringValue = (agent ? "SUBAGENT" : kind == "Dot" ? "CHAT · DOT" : "CHAT") + (contextOnly ? " · PARENT CONTEXT" : "")
        badge.textColor = agent ? .systemPurple : .systemBlue
        title.stringValue = task.displayTitle; title.toolTip = task.displayTitle
        var parts: [String] = []
        if !contextOnly { parts.append("\(ownCount) " + (ownCount == 1 ? "update" : "updates") + " shown") }
        if childChatCount > 0 { parts.append("\(childChatCount) child " + (childChatCount == 1 ? "chat" : "chats")) }
        if childSubagentCount > 0 { parts.append("\(childSubagentCount) " + (childSubagentCount == 1 ? "subagent" : "subagents")) }
        if selected > 0 { parts.append("\(selected) selected") }
        detail.stringValue = parts.joined(separator: " · ")
        if task.projectKey != projectKey { detail.stringValue += " · from " + (task.projectName ?? "No project") }
        detail.toolTip = detail.stringValue + ". Counts cover the loaded page; \(count) notifications including descendants."
        disclosure.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        disclosure.setAccessibilityLabel((collapsed ? "Expand " : "Collapse ") + task.displayTitle)
        openButton.isEnabled = !opening && TaskLaunch(thread: task.thread, host: task.host) != nil
        openButton.title = contextOnly ? "Open parent" : agent ? "Open agent" : "Open chat"
        openButton.toolTip = "Open this chat. Its notifications stay unchanged."
        openButton.setAccessibilityLabel("Open chat " + task.displayTitle)
        mapButton.isEnabled = task.host == "local"
        mapButton.setAccessibilityLabel("Map saved conversation " + task.displayTitle)
    }
}

/// AppKit owns range, modifier and keyboard selection. Checkboxes mirror the same IDs.
@MainActor final class NoticeTable: NSTableView {
    var selectEveryMatch: (() -> Void)?
    var clearSelection: (() -> Void)?
    var openSelection: (() -> Void)?
    var undoAction: (() -> Void)?
    var copyAction: (() -> Void)?
    var menuForRow: ((Int) -> NSMenu?)?
    private(set) var selectionModifiers: NSEvent.ModifierFlags = []
    override func mouseDown(with event: NSEvent) {
        selectionModifiers = event.modifierFlags
        defer { selectionModifiers = [] }
        super.mouseDown(with: event)
    }
    override func selectAll(_ sender: Any?) { selectEveryMatch?() }
    @objc func undo(_ sender: Any?) { undoAction?() }
    @objc func copy(_ sender: Any?) { copyAction?() }
    override func keyDown(with event: NSEvent) {
        selectionModifiers = event.modifierFlags
        defer { selectionModifiers = [] }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" { selectEveryMatch?(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" { undoAction?(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" { copyAction?(); return }
        if event.keyCode == 53 { clearSelection?(); return }
        if event.keyCode == 36 || event.keyCode == 76 { openSelection?(); return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        return index >= 0 ? menuForRow?(index) : nil
    }
}

@MainActor final class NoticeCell: NSTableCellView {
    private static let timelineDate: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "dd MMM yy\nHH:mm:ss"; formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()
    let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let glyph = NSImageView()
    let title = NSTextField(labelWithString: "")
    let actor = NSTextField(labelWithString: "")
    let preview = NSTextField(wrappingLabelWithString: "")
    let state = NSTextField(labelWithString: "")
    let date = NSTextField(labelWithString: "")
    let openButton = NSButton(title: "Open", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    var toggle: (() -> Void)?
    var open: (() -> Void)?
    var done: (() -> Void)?
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    override init(frame: NSRect) {
        super.init(frame: frame)
        actor.font = .systemFont(ofSize: 10, weight: .semibold); actor.lineBreakMode = .byTruncatingTail; actor.isHidden = true
        title.font = .systemFont(ofSize: 13, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        preview.font = .systemFont(ofSize: 12); preview.maximumNumberOfLines = 2; preview.lineBreakMode = .byTruncatingTail
        state.font = .systemFont(ofSize: 11); state.lineBreakMode = .byTruncatingTail
        date.font = .systemFont(ofSize: 10); date.alignment = .right
        check.target = self; check.action = #selector(toggled)
        openButton.target = self; openButton.action = #selector(opened)
        doneButton.target = self; doneButton.action = #selector(handled)
        for button in [openButton, doneButton] { button.bezelStyle = .rounded; button.controlSize = .small; button.font = .systemFont(ofSize: 11) }
        let text = NSStackView(views: [actor, title, preview, state]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 5
        let actions = NSStackView(views: [openButton, doneButton]); actions.spacing = 5
        let right = NSStackView(views: [date, actions]); right.orientation = .vertical; right.alignment = .trailing; right.spacing = 12
        for view in [check, glyph, text, right] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        glyph.imageScaling = .scaleProportionallyDown
        leading = check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        trailing = right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26)
        NSLayoutConstraint.activate([
            leading, check.centerYAnchor.constraint(equalTo: centerYAnchor), check.widthAnchor.constraint(equalToConstant: 20),
            glyph.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 9), glyph.topAnchor.constraint(equalTo: topAnchor, constant: 17), glyph.widthAnchor.constraint(equalToConstant: 18), glyph.heightAnchor.constraint(equalToConstant: 20),
            text.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 9), text.centerYAnchor.constraint(equalTo: centerYAnchor), text.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -12),
            trailing, right.centerYAnchor.constraint(equalTo: centerYAnchor), right.widthAnchor.constraint(equalToConstant: 108),
            actor.widthAnchor.constraint(equalTo: text.widthAnchor), title.widthAnchor.constraint(equalTo: text.widthAnchor), preview.widthAnchor.constraint(equalTo: text.widthAnchor), state.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        if abs(preview.preferredMaxLayoutWidth - preview.bounds.width) > 1 {
            preview.preferredMaxLayoutWidth = preview.bounds.width
            preview.invalidateIntrinsicContentSize()
        }
    }
    @objc private func toggled() { toggle?() }
    @objc private func opened() { open?() }
    @objc private func handled() { done?() }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { colors() } }
    private func colors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        for field in [preview, state, date] { field.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor }
    }
    func configure(_ row: StoredNotice, selected: Bool, opening: Bool, now: Double, depth: Int = 0, inTree: Bool = false, timelineActor: String? = nil, actorIsSubagent: Bool = false) {
        actor.isHidden = timelineActor == nil; actor.stringValue = timelineActor ?? ""
        actor.textColor = actorIsSubagent ? .systemPurple : .systemBlue; actor.toolTip = timelineActor
        let nodeDepth = CGFloat(max(0, depth - 1))
        leading.constant = inTree ? 56 + nodeDepth * 28 : 12 + CGFloat(depth) * 16
        trailing.constant = inTree ? -42 - nodeDepth * 12 : -26
        title.stringValue = inTree ? row.notice.inboxHeading : row.task.displayTitle; title.toolTip = row.task.displayTitle + " · " + row.notice.label
        preview.stringValue = row.notice.body.replacingOccurrences(of: "\n", with: " ")
        preview.toolTip = row.notice.body
        var parts = inTree ? [row.seen ? "Seen" : "Unseen"] : [row.notice.label, row.seen ? "Seen" : "Unseen"]
        if !row.needsAttention { parts.append("Done") }
        if !inTree {
            if let parent = row.parentLabel { parts.append(parent) }
            else if let origin = row.originLabel { parts.append(origin) }
            if let project = row.task.projectName { parts.append(project) }
        }
        if row.notice.resolution == "request_ended" && row.needsAttention { parts.append("Request ended · answer unknown") }
        if !row.notice.resolved, let deadline = row.notice.deadline {
            let left = max(0, Int(deadline - Date().timeIntervalSince1970))
            parts.append(row.notice.estimated == true ? (left > 0 ? "~\(left)s · panel" : "Panel timer elapsed · estimated") : (left > 0 ? "\(left)s · deadline" : "Deadline elapsed"))
        } else if !row.notice.resolved && row.notice.timerUnavailable == true { parts.append("Timer unavailable") }
        if let banner = row.banner, banner.state != "accepted" { parts.append(banner.state == "failed" ? "Banner failed" : "Banner acceptance unknown") }
        state.stringValue = parts.joined(separator: " · "); state.toolTip = state.stringValue
        date.maximumNumberOfLines = timelineActor == nil ? 1 : 2
        date.cell?.usesSingleLineMode = timelineActor == nil
        date.lineBreakMode = timelineActor == nil ? .byTruncatingTail : .byWordWrapping
        date.stringValue = row.notice.timeSource == "unknown" ? "Time unknown" : timelineActor == nil ? DisplayTime.ago(row.notice.created, now: now) : Self.timelineDate.string(from: Date(timeIntervalSince1970: row.notice.created))
        date.toolTip = row.notice.timeSource == "unknown" ? "Original source time is unknown" : DisplayTime.full(row.notice.created) + (row.notice.timeSource == "observed" ? " · Observed by Inbox" : " · Source event time")
        glyph.image = NSImage(systemSymbolName: row.notice.symbol, accessibilityDescription: row.notice.label)
        glyph.contentTintColor = NSColor(row.notice.tint)
        check.state = selected ? .on : .off
        check.setAccessibilityLabel("Select " + row.task.displayTitle)
        openButton.title = opening ? "Opening…" : "Open"; openButton.isEnabled = row.notice.url != nil && !opening
        openButton.toolTip = "Open in Codex and mark this notification seen. Attention stays unchanged."
        doneButton.title = row.needsAttention ? "Done" : "Reopen"
        doneButton.toolTip = row.needsAttention ? "Mark this notification done" : "Return this notification to Needs attention"
        setAccessibilityLabel(row.task.displayTitle + ". " + state.stringValue + ". " + preview.stringValue)
        colors()
    }
}

extension Notice {
    var inboxHeading: String {
        switch kind {
        case "completion": return turn == nil ? "Completion update" : "Final reply · Turn completed"
        case "question": return "Question for you"
        case "approval": return "Permission requested"
        case "input": return "Tool input requested"
        case "error": return terminalStatus == "interrupted" ? "Turn interrupted" : terminalStatus == "failed" ? "Turn failed" : label
        default: return label
        }
    }
}

@MainActor final class NoticeSelectionRow: NSTableRowView {
    var entry = NoticeListEntry()
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawBackground(in dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 12, dy: 0)
        let path: NSBezierPath
        if entry.project != nil {
            let extended = NSRect(x: box.minX, y: isFlipped ? 0 : -10, width: box.width, height: box.height + 10)
            path = NSBezierPath(roundedRect: extended, xRadius: 10, yRadius: 10)
        } else if entry.endsProject {
            let extended = NSRect(x: box.minX, y: isFlipped ? -10 : box.height - 10, width: box.width, height: 20)
            path = NSBezierPath(roundedRect: extended, xRadius: 10, yRadius: 10)
        } else { path = NSBezierPath(rect: box) }
        NSColor.controlBackgroundColor.setFill(); path.fill()
        let accent = NSColor(Color.inboxAccent)
        accent.withAlphaComponent(entry.project != nil ? 0.09 : 0.025).setFill(); path.fill()
        accent.withAlphaComponent(0.3).setStroke(); path.lineWidth = 1
        if entry.project != nil || entry.endsProject { path.stroke() }
        else {
            let border = NSBezierPath(); border.move(to: NSPoint(x: box.minX, y: box.minY)); border.line(to: NSPoint(x: box.minX, y: box.maxY))
            border.move(to: NSPoint(x: box.maxX, y: box.minY)); border.line(to: NSPoint(x: box.maxX, y: box.maxY)); border.stroke()
        }
        for conversation in entry.boxes {
            let start = entry.group?.key == conversation.key
            let end = entry.conversationEnd == conversation.key
            let rect: NSRect
            if start { rect = NSRect(x: conversation.left, y: isFlipped ? 8 : -10, width: max(0, bounds.width - conversation.left - conversation.rightInset), height: bounds.height + 2) }
            else if end { rect = NSRect(x: conversation.left, y: isFlipped ? -10 : bounds.height - 10, width: max(0, bounds.width - conversation.left - conversation.rightInset), height: 20) }
            else { rect = NSRect(x: conversation.left, y: 0, width: max(0, bounds.width - conversation.left - conversation.rightInset), height: bounds.height) }
            let panel = start || end ? NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9) : NSBezierPath(rect: rect)
            NSColor.controlBackgroundColor.setFill(); panel.fill()
            let tint: NSColor = conversation.isSubagent ? .systemPurple : .systemBlue
            tint.withAlphaComponent(start ? 0.1 : 0.025).setFill(); panel.fill()
            tint.withAlphaComponent(0.3).setStroke()
            if start || end { panel.stroke() }
            else {
                let edge = NSBezierPath()
                edge.move(to: NSPoint(x: rect.minX, y: 0)); edge.line(to: NSPoint(x: rect.minX, y: bounds.height))
                edge.move(to: NSPoint(x: rect.maxX, y: 0)); edge.line(to: NSPoint(x: rect.maxX, y: bounds.height)); edge.stroke()
            }
        }
        if entry.notice != nil {
            let nodeDepth = CGFloat(entry.boxes.last?.depth ?? 0)
            let left = 82 + nodeDepth * 28
            let card = NSRect(x: left, y: 7, width: max(0, bounds.width - left - 32 - nodeDepth * 12), height: bounds.height - 14)
            let panel = NSBezierPath(roundedRect: card, xRadius: 7, yRadius: 7)
            NSColor.labelColor.withAlphaComponent(0.025).setFill(); panel.fill()
            NSColor.labelColor.withAlphaComponent(0.07).setStroke(); panel.stroke()
        }
        guard entry.project == nil && !entry.endsProject else { return }
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: isFlipped ? y : bounds.height - y) }
        let tree = NSBezierPath(); tree.lineWidth = 1
        let middle = bounds.height / 2
        for (level, continues) in entry.branches.enumerated() {
            let current = entry.group != nil && level == entry.branches.count - 1
            if continues || current {
                let x = 46 + CGFloat(level) * 28
                tree.move(to: point(x, 0)); tree.line(to: point(x, continues ? bounds.height : middle))
            }
        }
        if entry.group != nil && entry.depth > 0 {
            tree.move(to: point(46 + CGFloat(entry.depth - 1) * 28, middle))
            tree.line(to: point(36 + CGFloat(entry.depth) * 28, middle))
        }
        if entry.startsChildren {
            let x = 46 + CGFloat(entry.depth) * 28
            tree.move(to: point(x, middle)); tree.line(to: point(x, bounds.height))
        }
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke(); tree.stroke()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
        let box = entry.boxes.last
        let left = (box?.left ?? 0) + 24
        let rect = NSRect(x: left, y: 3, width: max(0, bounds.width - left - (box?.rightInset ?? 12) - 8), height: bounds.height - 6)
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }
}

struct NativeNoticeList: NSViewRepresentable {
    @ObservedObject var inbox: Inbox
    var layout: NoticeListLayout = .byChat
    var showMap: ((TaskIdentity) -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator(inbox) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let table = NoticeTable(); table.headerView = nil; table.style = .plain; table.rowHeight = 94
        table.intercellSpacing = .zero; table.allowsMultipleSelection = true
        table.allowsEmptySelection = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .controlBackgroundColor
        let column = NSTableColumn(identifier: .init("notification")); column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.doubleClick)
        table.setAccessibilityLabel("Notifications")
        context.coordinator.table = table
        table.selectEveryMatch = { [weak inbox] in inbox?.selectAllNotices() }
        table.clearSelection = { [weak inbox] in inbox?.selectedIDs = [] }
        table.openSelection = { [weak coordinator = context.coordinator] in coordinator?.openSelected() }
        table.undoAction = { [weak inbox] in inbox?.undoLastAction() }
        table.copyAction = { [weak inbox] in inbox?.copySelection(links: false) }
        table.menuForRow = { [weak coordinator = context.coordinator] index in coordinator?.menu(index) }
        scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.showMap = showMap
        context.coordinator.update(inbox, scroll: scroll, layout: layout)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var inbox: Inbox
        weak var table: NoticeTable?
        var entries: [NoticeListEntry] = []
        var rows: [StoredNotice] { entries.compactMap(\.notice) }
        var collapsed: Set<String> = []
        var updating = false
        var anchor: String?
        var scope: InboxQuery?
        var layout: NoticeListLayout = .byChat
        var showMap: ((TaskIdentity) -> Void)?
        var menuActions: [Int: () -> Void] = [:]
        init(_ inbox: Inbox) { self.inbox = inbox }
        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let entry = entries[row]
            if entry.endsProject || entry.conversationEnd != nil { return 18 }
            if entry.notice != nil { return entry.timelineActor == nil ? 94 : 112 }
            if entry.group != nil { return 80 }
            return entry.content != nil ? 50 : 58
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { entries[row].notice != nil }
        func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
            IndexSet(proposed.filter { entries.indices.contains($0) && entries[$0].notice != nil })
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = NoticeSelectionRow(); view.entry = entries[row]; return view
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard entries.indices.contains(row) else { return nil }
            let entry = entries[row]
            if let project = entry.project {
                let id = NSUserInterfaceItemIdentifier("project-header")
                let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NoticeProjectCell) ?? NoticeProjectCell()
                cell.identifier = id; configure(cell, entry: entry, project: project); return cell
            }
            if let section = entry.content, let box = entry.boxes.last {
                let id = NSUserInterfaceItemIdentifier("chat-section")
                let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NoticeContentCell) ?? NoticeContentCell()
                cell.identifier = id; cell.configure(section, box: box); return cell
            }
            if let group = entry.group {
                let id = NSUserInterfaceItemIdentifier("parent-chat")
                let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NoticeGroupCell) ?? NoticeGroupCell()
                cell.identifier = id
                configure(cell, entry: entry)
                cell.toggle = { [weak self] in self?.toggleGroup(group.key) }
                cell.open = { [weak inbox] in inbox?.open(group) }
                cell.showMap = { [weak self] in self?.showMap?(group) }
                return cell
            }
            guard let item = entry.notice else { return nil }
            let id = NSUserInterfaceItemIdentifier("notice-cell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NoticeCell) ?? NoticeCell()
            cell.identifier = id
            cell.configure(item, selected: inbox.selectedIDs.contains(item.id), opening: inbox.isOpening(item.notice.url), now: inbox.clock.stamp().at, depth: entry.depth, inTree: true, timelineActor: entry.timelineActor, actorIsSubagent: entry.actorIsSubagent)
            cell.toggle = { [weak self] in self?.checkbox(item.id) }
            cell.open = { [weak inbox] in inbox?.open(item) }
            cell.done = { [weak inbox] in inbox?.markDone(item, done: item.needsAttention) }
            return cell
        }
        private func configure(_ cell: NoticeGroupCell, entry: NoticeListEntry) {
            guard let group = entry.group else { return }
            let selected = entry.memberIDs.filter { inbox.selectedIDs.contains($0) }.count
            let kind = group.origin == "dot" ? "Dot" : inbox.snapshot.taskCatalog[group.key]?.isSubagent == true ? "Subagent" : "Chat"
            cell.configure(group, count: entry.count, ownCount: entry.ownCount, childChatCount: entry.childChatCount, childSubagentCount: entry.childSubagentCount, selected: selected, collapsed: collapsed.contains(group.key), opening: inbox.isOpening(TaskLaunch(thread: group.thread, host: group.host)?.url), depth: entry.depth, kind: kind, contextOnly: entry.contextOnly, projectKey: entry.projectKey)
        }
        private func configure(_ cell: NoticeProjectCell, entry: NoticeListEntry, project: NoticeProjectHeader) {
            cell.configure(project, count: entry.count, selected: entry.memberIDs.filter { inbox.selectedIDs.contains($0) }.count)
        }
        func toggleGroup(_ key: String) {
            if !collapsed.insert(key).inserted { collapsed.remove(key) }
            if let scroll = table?.enclosingScrollView { update(inbox, scroll: scroll, layout: layout) }
        }
        func update(_ inbox: Inbox, scroll: NSScrollView, layout: NoticeListLayout = .byChat) {
            self.inbox = inbox
            guard let table else { return }
            let scopeChanged = scope != inbox.query.selectionScope
            let layoutChanged = self.layout != layout; self.layout = layout
            var point = scopeChanged || layoutChanged ? NSPoint.zero : scroll.contentView.bounds.origin
            let first = table.row(at: point)
            let topID = !scopeChanged && !layoutChanged && entries.indices.contains(first) ? entries[first].id : nil
            let offset = first >= 0 ? point.y - table.rect(ofRow: first).minY : 0
            if scopeChanged { anchor = nil; scope = inbox.query.selectionScope; collapsed = [] }
            updating = true
            let next = NoticeGrouping.entries(inbox.snapshot.notices, catalog: inbox.snapshot.taskCatalog, collapsed: collapsed, layout: layout)
            let changed = entries != next
            entries = next
            if changed { table.reloadData() }
            let indexes = IndexSet(entries.indices.filter { entries[$0].notice.map { inbox.selectedIDs.contains($0.id) } == true })
            if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound {
                for index in visible.location..<min(entries.count, NSMaxRange(visible)) {
                    let entry = entries[index]
                    if let row = entry.notice {
                        (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NoticeCell)?.configure(row, selected: indexes.contains(index), opening: inbox.isOpening(row.notice.url), now: inbox.clock.stamp().at, depth: entry.depth, inTree: true, timelineActor: entry.timelineActor, actorIsSubagent: entry.actorIsSubagent)
                    } else if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NoticeGroupCell { configure(cell, entry: entry) }
                    else if let project = entry.project, let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NoticeProjectCell { configure(cell, entry: entry, project: project) }
                }
            }
            if changed {
                if let topID, let index = entries.firstIndex(where: { $0.id == topID }) { point.y = table.rect(ofRow: index).minY + offset }
                scroll.contentView.scroll(to: point); scroll.reflectScrolledClipView(scroll.contentView)
            }
            updating = false
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            let visible = Set(rows.map(\.id))
            let indexes = table.selectedRowIndexes.filter { entries.indices.contains($0) && entries[$0].notice != nil }
            var selection = Set(indexes.compactMap { entries[$0].notice?.id })
            if table.selectionModifiers.contains(.command) { selection.formUnion(inbox.selectedIDs.subtracting(visible)) }
            inbox.selectedIDs = selection
            if !table.selectionModifiers.contains(.shift), let row = indexes.first { anchor = entries[row].notice?.id }
        }
        func checkbox(_ id: String, modifiers suppliedModifiers: NSEvent.ModifierFlags? = nil) {
            let modifiers = suppliedModifiers ?? NSApp.currentEvent?.modifierFlags ?? []
            if modifiers.contains(.shift), let anchor, let first = rows.firstIndex(where: { $0.id == anchor }), let last = rows.firstIndex(where: { $0.id == id }) {
                let range = Set(rows[min(first, last)...max(first, last)].map(\.id))
                inbox.selectedIDs = modifiers.contains(.command) ? inbox.selectedIDs.union(range) : range
            } else { inbox.toggleSelection(id); anchor = id }
        }
        @objc func doubleClick() {
            guard let table, entries.indices.contains(table.clickedRow) else { return }
            if let group = entries[table.clickedRow].group { toggleGroup(group.key) }
            else if inbox.selectedIDs.count <= 1, let row = entries[table.clickedRow].notice { inbox.open(row) }
        }
        func openSelected() {
            guard inbox.selectedIDs.count == 1, let row = rows.first(where: { inbox.selectedIDs.contains($0.id) }) else { return }
            inbox.open(row)
        }
        func menu(_ index: Int) -> NSMenu? {
            guard entries.indices.contains(index), let item = entries[index].notice else { return nil }
            if !inbox.selectedIDs.contains(item.id) { inbox.selectedIDs = [item.id] }
            let ids = inbox.selectedIDs, menu = NSMenu()
            menuActions = [:]
            func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
                let value = NSMenuItem(title: title, action: #selector(runMenu(_:)), keyEquivalent: "")
                value.target = self; value.tag = menuActions.count; value.isEnabled = enabled
                menuActions[value.tag] = action; menu.addItem(value)
            }
            menu.autoenablesItems = false
            if ids.count == 1 { add("Open in Codex", enabled: item.notice.url != nil) { [weak inbox] in inbox?.open(item) } }
            for action in [NoticeAction.seen, .unseen, .done, .reopen] {
                add(action.rawValue + (ids.count > 1 ? " (\(ids.count))" : ""), enabled: !inbox.batchBusy) { [weak inbox] in inbox?.perform(action, ids: ids) }
            }
            menu.addItem(.separator())
            add("Copy task links") { [weak inbox] in inbox?.copySelection(links: true, ids: ids) }
            add("Copy text") { [weak inbox] in inbox?.copySelection(links: false, ids: ids) }
            if ids.count == 1 {
                if let parent = item.parentTask { add("Open parent chat") { [weak inbox] in inbox?.open(parent) } }
                add("Details") { [weak inbox] in inbox?.detailNotice = item }
                add("Task history") { [weak inbox] in inbox?.showHistory(item.task) }
                if let banner = item.banner, banner.state != "accepted" { add("Retry banner") { [weak inbox] in inbox?.retryBanner(item) } }
            }
            return menu
        }
        @objc func runMenu(_ sender: NSMenuItem) { menuActions[sender.tag]?() }
    }
}
