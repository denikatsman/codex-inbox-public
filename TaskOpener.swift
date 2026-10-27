import AppKit
import Combine

enum TaskOpenFailure: Error, Equatable {
    case appMissing, applicationExited, timedOut, system(String)

    var message: String {
        switch self {
        case .appMissing: return "Codex could not be found in Applications."
        case .applicationExited: return "Codex quit before the task could be opened."
        case .timedOut: return "Codex did not confirm opening in time. Check Codex before trying again."
        case .system(let detail): return "Could not open Codex: \(detail)"
        }
    }
}

/// Owns launch attempts so an error, missing callback, or stale callback cannot
/// silently complete a newer opening. The injected launcher keeps tests off the desktop.
@MainActor final class TaskOpener: ObservableObject {
    typealias Completion = @MainActor (Result<Void, TaskOpenFailure>) -> Void
    typealias Launcher = @MainActor (TaskLaunch, @escaping Completion) -> Void
    @Published private(set) var opening: Set<URL> = []
    @Published var error = ""
    private var pending: [URL: (id: UUID, timeout: Task<Void, Never>)] = [:]
    private let launch: Launcher
    private let timeoutNanoseconds: UInt64

    init(launcher: Launcher? = nil, timeoutNanoseconds: UInt64 = 30_000_000_000) {
        self.launch = launcher ?? Self.openInWorkspace
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func open(_ request: TaskLaunch, onResult: Completion? = nil, onAccepted: @escaping @MainActor () -> Void) {
        guard pending[request.url] == nil else { return }
        let id = UUID()
        error = ""
        opening.insert(request.url)
        let timeout = Task { [weak self, timeoutNanoseconds] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
            self?.finish(request.url, id: id, result: .failure(.timedOut), onResult: onResult, onAccepted: onAccepted)
        }
        pending[request.url] = (id, timeout)
        launch(request) { [weak self] result in
            self?.finish(request.url, id: id, result: result, onResult: onResult, onAccepted: onAccepted)
        }
    }

    private func finish(_ url: URL, id: UUID, result: Result<Void, TaskOpenFailure>,
                        onResult: Completion?, onAccepted: @MainActor () -> Void) {
        guard let attempt = pending[url], attempt.id == id else { return }
        attempt.timeout.cancel()
        pending.removeValue(forKey: url)
        opening.remove(url)
        onResult?(result)
        switch result {
        case .success: onAccepted()
        case .failure(let failure): error = failure.message + " The notification has not been marked done."
        }
    }

    private static func openInWorkspace(_ request: TaskLaunch, completion: @escaping Completion) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TaskLaunch.bundleID) else {
            completion(.failure(.appMissing)); return
        }
        NSWorkspace.shared.open([request.url], withApplicationAt: appURL, configuration: request.configuration()) { app, error in
            Task { @MainActor in
                if let error { completion(.failure(.system(error.localizedDescription))); return }
                guard let app else { completion(.failure(.applicationExited)); return }
                // Launch Services can report success before an app immediately
                // quits. Recheck after that startup interval; no retry or fallback.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard TaskLaunch.acceptsApplication(bundleID: app.bundleIdentifier, terminated: app.isTerminated) else {
                    completion(.failure(.applicationExited)); return
                }
                // This confirms OS handoff and a surviving Codex process, not
                // that its renderer finished loading the requested task.
                completion(.success(()))
            }
        }
    }
}
