#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
task_app="dist/delivery/Codex Inbox.app"
[[ ! -e "$task_app" ]] || { echo "Review existing candidate first" >&2; exit 2; }
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources" build/AppIcon.iconset
/usr/bin/python3 - <<'PY'
from pathlib import Path
import plistlib
Path('dist/delivery/Codex Inbox.app/Contents/Info.plist').write_bytes(plistlib.dumps({
 'CFBundleIdentifier':'local.codex.inbox', 'CFBundleName':'Codex Inbox',
 'CFBundleDisplayName':'Codex Inbox', 'CFBundleExecutable':'CodexInbox',
 'CFBundlePackageType':'APPL', 'CFBundleShortVersionString':'2.10',
 'CFBundleVersion':'18', 'LSMinimumSystemVersion':'14.0',
 'LSUIElement':True, 'NSHighResolutionCapable':True, 'CFBundleIconFile':'AppIcon'}))
PY
xcrun swiftc -parse-as-library -swift-version 5 -O -framework AppKit -framework SwiftUI -framework UserNotifications -lsqlite3 AppAccess.swift AppInstance.swift TaskLaunch.swift TaskOpener.swift InboxModels.swift InboxStore.swift InboxStore+Views.swift TimelineClock.swift InboxController.swift InboxViews.swift NativeNoticeList.swift ConversationMap.swift SavedMessages.swift InboxWindow.swift InboxCard.swift InboxPresentation.swift Inbox.swift -o "$task_app/Contents/MacOS/CodexInbox"
cp Resources/AppIcon.icns "$task_app/Contents/Resources/AppIcon.icns"
cp collector.py "$task_app/Contents/Resources/collector.py"
cp conversation_map.py "$task_app/Contents/Resources/conversation_map.py"
codesign --force --options runtime --sign - --identifier local.codex.inbox "$task_app"
codesign --verify --strict "$task_app"
