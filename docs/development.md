# Development

The app consists of SwiftUI/AppKit views, an append-only SQLite activity store, and a Python collector. `collector.py` follows Codex's local IPC and reads local history; `conversation_map.py` reads saved conversations for the Messages and Map views. Both treat Codex data as read-only. `InboxStore.swift` and `InboxStore+Views.swift` own durable attention state and activity; `InboxController.swift` coordinates ingestion and notifications. `TaskLaunch.swift` and `TaskOpener.swift` handle explicit task opens. `InboxWindow.swift`, `InboxViews.swift`, `SavedMessages.swift`, and `InboxCard.swift` provide the interface.

Run `zsh test.sh` for the Python and native tests, and `zsh build.sh` to build an ad-hoc-signed app at `dist/delivery/Codex Inbox.app`. The tests use synthetic or temporary data; task-opening tests use an injected launcher and do not navigate Codex. They do not prove that macOS displayed a banner or that a task rendered in Codex.

Preserve the boundaries that make the inbox reliable: record opening attempts before launching, keep Seen and Done independent, retain source and capture timestamps separately, and avoid changing Codex data. The collector uses private interfaces, so compatibility may change with Codex updates. See [activity history](activity-history.md) for storage and clock behavior.
