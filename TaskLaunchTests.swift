import AppKit

@main struct TaskLaunchTests {
    @MainActor static func main() async {
        let task = "00000000-0000-4000-8000-000000000001"
        let request = TaskLaunch(thread: task, host: "local")!
        precondition(request.url.absoluteString == "codex://threads/\(task)")
        let config = request.configuration()
        precondition(!config.createsNewApplicationInstance && config.arguments.isEmpty)
        precondition(config.activates && !config.hidesOthers && !config.promptsUserIfNeeded)
        for bad in ["", "new", "../settings", "task?prompt=run", "task/new", "task\n", "task#fragment", " task", "tâsk"] {
            precondition(TaskLaunch(thread: bad, host: "local") == nil)
        }
        precondition(TaskLaunch(thread: task, host: "") == nil)
        let remote = TaskLaunch(thread: task, host: "machine & other=1")!
        let query = URLComponents(url: remote.url, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.count == 1 && query[0].name == "hostId" && query[0].value == "machine & other=1")
        precondition(TaskLaunch.acceptsApplication(bundleID: "com.openai.codex", terminated: false))
        precondition(!TaskLaunch.acceptsApplication(bundleID: "com.openai.codex", terminated: true))
        precondition(!TaskLaunch.acceptsApplication(bundleID: nil, terminated: false))
        precondition(!TaskLaunch.acceptsApplication(bundleID: "another.app", terminated: false))

        var calls: [TaskLaunch] = []
        var callbacks: [TaskOpener.Completion] = []
        var accepted = 0
        let opener = TaskOpener(launcher: { request, completion in
            calls.append(request); callbacks.append(completion)
        })
        // Creating the opener does nothing. Rapid clicks on the same task,
        // including different alerts for it, make only one OS request.
        precondition(calls.isEmpty)
        opener.open(request) { accepted += 1 }
        opener.open(request) { accepted += 1 }
        precondition(calls == [request] && accepted == 0 && opener.opening == [request.url])
        callbacks[0](.failure(.applicationExited))
        precondition(accepted == 0 && opener.opening.isEmpty && !opener.error.isEmpty)
        let persistentError = opener.error
        await Task.yield()
        precondition(opener.error == persistentError)
        opener.open(request) { accepted += 1 }
        callbacks[0](.success(())) // A late response to the failed attempt.
        precondition(accepted == 0 && opener.opening == [request.url])
        callbacks[1](.success(()))
        callbacks[1](.success(())) // Repeated callbacks cannot mark twice.
        precondition(accepted == 1 && opener.opening.isEmpty && opener.error.isEmpty)

        for failure in [TaskOpenFailure.appMissing, .system("OS refused the URL")] {
            let failing = TaskOpener(launcher: { _, done in done(.failure(failure)) })
            failing.open(request) { accepted += 1 }
            precondition(accepted == 1 && failing.opening.isEmpty && failing.error.contains(failure.message))
        }

        var delayed: [TaskOpener.Completion] = []
        let stalled = TaskOpener(launcher: { _, done in delayed.append(done) }, timeoutNanoseconds: 20_000_000)
        stalled.open(request) { accepted += 1 }
        try! await Task.sleep(nanoseconds: 80_000_000)
        precondition(stalled.opening.isEmpty && stalled.error.contains(TaskOpenFailure.timedOut.message))
        stalled.open(request) { accepted += 1 }
        delayed[0](.success(())) // Timeout from a previous click cannot accept a retry.
        precondition(accepted == 1 && stalled.opening == [request.url])
        delayed[1](.success(()))
        precondition(accepted == 2 && stalled.opening.isEmpty)
        try! await Task.sleep(nanoseconds: 40_000_000)
        precondition(stalled.error.isEmpty) // Completed attempts cancel their timeout.

        opener.open(request) { accepted += 1 }
        opener.open(remote) { accepted += 1 }
        precondition(opener.opening.count == 2)
        callbacks[2](.success(()))
        callbacks[3](.failure(.applicationExited))
        precondition(accepted == 3 && opener.opening.isEmpty && !opener.error.isEmpty)
        print("Task opening checks passed: standard URL configuration, invalid links, app exit, missing app, OS errors, duplicate clicks, timeout, stale callbacks, retry, and independent tasks. No application was opened.")
    }
}
