import Foundation
import Combine

/// ContinuousClock advances across sleep and ignores manual wall-clock edits.
/// Durable activity sequence numbers remain authoritative for capture order.
final class TimelineClock: @unchecked Sendable {
    private let lock = NSLock()
    private let elapsedNow: () -> Double
    private let wallNow: () -> Double
    private var anchorTime: Double
    private var anchorElapsed: Double
    private var verifiedElapsed: Double?
    private let session = UUID().uuidString

    init(wall: @escaping () -> Double = { Date().timeIntervalSince1970 }, elapsed: (() -> Double)? = nil) {
        let start = ContinuousClock.now
        let elapsed = elapsed ?? {
            let d = start.duration(to: .now).components
            return Double(d.seconds) + Double(d.attoseconds) / 1e18
        }
        wallNow = wall; elapsedNow = elapsed
        anchorTime = wall(); anchorElapsed = elapsed()
    }
    func stamp() -> EventTime {
        lock.lock(); defer { lock.unlock() }
        let elapsed = elapsedNow(), wall = wallNow()
        let effective = anchorTime + elapsed - anchorElapsed
        let quality: String
        if let checked = verifiedElapsed { quality = elapsed - checked <= 86400 ? "Network checked" : "Estimated from last clock check" }
        else { quality = abs(wall - effective) > 5 ? "Device clock changed; elapsed time preserved" : "Device time; not network checked" }
        return EventTime(at: effective, deviceAt: wall, elapsed: elapsed, session: session, quality: quality)
    }
    /// HTTP Date is a coarse sanity check, not a precision or signed timestamp.
    /// Ignore cached/slow responses instead of silently using misleading time.
    @discardableResult func accept(date: Double, age: Double?, roundTrip: Double) -> Bool {
        guard date.isFinite, roundTrip >= 0, roundTrip <= 5, (age ?? 0) >= 0, (age ?? 0) <= 2 else { return false }
        lock.lock(); defer { lock.unlock() }
        anchorElapsed = elapsedNow()
        anchorTime = date + (age ?? 0) + roundTrip / 2
        verifiedElapsed = anchorElapsed
        return true
    }
}

@MainActor final class ClockCheck: ObservableObject {
    @Published private(set) var status = "Clock not checked yet"
    @Published private(set) var warning = ""
    let clock: TimelineClock
    private var loop: Task<Void, Never>?
    private let defaults: UserDefaults
    private var checking = false
    init(clock: TimelineClock, defaults: UserDefaults = .standard) { self.clock = clock; self.defaults = defaults }
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.check()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(6 * 3600)) } catch { return }
                await self?.check()
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    func check(force: Bool = false) async {
        guard !checking else { return }
        // Persist the last attempt so repeated utility restarts cannot cause a
        // request loop. The cache is informative, never a trusted clock anchor.
        let now = Date().timeIntervalSince1970
        let last = defaults.double(forKey: "clockLastAttempt")
        if !force, now >= last, now - last < 60 {
            status = "Last clock check: " + (defaults.string(forKey: "clockLastResult") ?? "unavailable")
            return
        }
        checking = true; defer { checking = false }
        defaults.set(now, forKey: "clockLastAttempt")
        let start = ContinuousClock.now
        var request = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html?inbox_clock=" + UUID().uuidString)!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let date = http.value(forHTTPHeaderField: "Date") else { throw URLError(.badServerResponse) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let duration = start.duration(to: .now).components
            let roundTrip = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            guard let serverTime = formatter.date(from: date),
                  clock.accept(date: serverTime.timeIntervalSince1970,
                               age: http.value(forHTTPHeaderField: "Age").flatMap(Double.init), roundTrip: roundTrip) else { throw URLError(.badServerResponse) }
            let stamp = clock.stamp(), difference = stamp.at - stamp.deviceAt
            if abs(difference) > 30 {
                warning = "Your Mac’s clock differs from the network check by about \(Int(abs(difference))) seconds. New activity uses the checked time; the Mac’s settings were not changed."
                status = "Clock difference: \(Int(abs(difference))) seconds"
            } else { warning = ""; status = "Clock checked · in sync" }
        } catch {
            status = "Network clock check unavailable"
            // Offline is normal. Stamp provenance still says whether an earlier
            // network anchor exists; neither events nor the UI are blocked.
        }
        defaults.set(status, forKey: "clockLastResult")
    }
}
