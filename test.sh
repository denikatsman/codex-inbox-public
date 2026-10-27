#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
/usr/bin/python3 -m unittest -v test_collector.py test_repairs.py test_historical_repair.py test_task_tracking.py test_conversation_map.py
xcrun swiftc -parse-as-library -swift-version 5 AppInstance.swift AppInstanceProbe.swift -o build/app-instance-probe
/usr/bin/python3 -m unittest -v test_app_instance.py
xcrun swiftc -parse-as-library -swift-version 5 TaskLaunch.swift TaskOpener.swift TaskLaunchTests.swift -o build/task-launch-tests
build/task-launch-tests
xcrun swiftc -parse-as-library -swift-version 5 -framework AppKit -framework SwiftUI -framework UserNotifications -lsqlite3 AppAccess.swift AppInstance.swift TaskLaunch.swift TaskOpener.swift InboxModels.swift InboxStore.swift InboxStore+Views.swift TimelineClock.swift InboxController.swift InboxViews.swift NativeNoticeList.swift ConversationMap.swift SavedMessages.swift InboxWindow.swift InboxCard.swift InboxPresentation.swift InboxStoreTests.swift -o build/inbox-store-tests
build/inbox-store-tests

xcrun swiftc -parse-as-library -swift-version 5 -framework AppKit -framework SwiftUI -framework UserNotifications -lsqlite3 AppAccess.swift AppInstance.swift TaskLaunch.swift TaskOpener.swift InboxModels.swift InboxStore.swift InboxStore+Views.swift TimelineClock.swift InboxController.swift InboxViews.swift NativeNoticeList.swift ConversationMap.swift SavedMessages.swift InboxWindow.swift InboxCard.swift InboxPresentation.swift InboxRepairTests.swift -o build/inbox-repair-tests
build/inbox-repair-tests
/usr/bin/python3 - <<'PYTHON'
import subprocess
results=[]
for count in (1000,10000):
    output=subprocess.run(['build/inbox-repair-tests','--stream-memory',str(count)],capture_output=True,text=True,check=True).stdout.strip()
    print(output)
    results.append(int(output.split()[-1]))
assert results[1]-results[0] < 24*1024*1024, results
PYTHON

xcrun swiftc -parse-as-library -swift-version 5 -framework AppKit -framework SwiftUI -framework UserNotifications -lsqlite3 AppAccess.swift AppInstance.swift TaskLaunch.swift TaskOpener.swift InboxModels.swift InboxStore.swift InboxStore+Views.swift TimelineClock.swift InboxController.swift InboxViews.swift NativeNoticeList.swift ConversationMap.swift SavedMessages.swift InboxWindow.swift InboxCard.swift InboxPresentation.swift InboxFeatureTests.swift -o build/inbox-feature-tests
build/inbox-feature-tests
