import Foundation
import OSLog
import UserNotifications

private let log = Logger(subsystem: "local.firewalladock.app", category: "threatintel")

/// Reputation lookups for alarm IPs and domains: settings, queue, rate limits and cache.
@MainActor
final class ThreatIntel: ObservableObject {
    static let shared = ThreatIntel()

    // Settings
    @Published var enabled: Set<ThreatService> {
        didSet { UserDefaults.standard.set(enabled.map(\.rawValue), forKey: "threatIntelEnabled"); processQueue() }
    }
    @Published var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "threatIntelAutoCheck") }
    }
    /// API keys, stored in the Keychain
    @Published private(set) var keys: [ThreatService: String] = [:]

    // State
    @Published private(set) var reports: [String: ReputationReport] = [:]
    @Published private(set) var inProgress: Set<String> = []
    @Published private(set) var queued: [Indicator] = []
    @Published private(set) var usedToday: [ThreatService: Int] = [:]

    private let client = ThreatIntelClient()
    private var worker: Task<Void, Never>?
    private var lastRequest: [ThreatService: Date] = [:]
    private var pausedUntil: [ThreatService: Date] = [:]
    /// Alarms already considered by the automatic check; anything else is "new".
    private var autoSeenAlarmIDs: Set<String>?
    private static let cacheTTL: TimeInterval = 24 * 3600

    private init() {
        let d = UserDefaults.standard
        enabled = Set((d.stringArray(forKey: "threatIntelEnabled") ?? []).compactMap(ThreatService.init))
        autoCheck = d.object(forKey: "threatIntelAutoCheck") as? Bool ?? true
        for s in ThreatService.allCases where s.needsKey { keys[s] = Keychain.load(s.keychainAccount) }
        if let ids = d.stringArray(forKey: "threatIntelAutoSeen") { autoSeenAlarmIDs = Set(ids) }
        loadUsage()
        loadCache()
    }

    // MARK: Settings

    func setKey(_ key: String, for service: ThreatService) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        keys[service] = key
        Keychain.save(key, account: service.keychainAccount)
        if key.isEmpty { enabled.remove(service) }
    }

    /// A service is used only when enabled and, if it needs one, it has a key.
    func isActive(_ s: ThreatService) -> Bool {
        enabled.contains(s) && (!s.needsKey || !(keys[s] ?? "").isEmpty)
    }
    var activeServices: [ThreatService] { ThreatService.allCases.filter(isActive) }
    var isConfigured: Bool { !activeServices.isEmpty }

    func clearCache() {
        reports = [:]
        saveCache()
    }

    // MARK: Results for an alarm

    func report(for ind: Indicator) -> ReputationReport? { reports[ind.id] }

    /// Worst verdict over the alarm's indicators, or nil if none was checked.
    func level(for alarm: Alarm) -> ThreatLevel? {
        let levels = Indicator.from(alarm).compactMap { reports[$0.id]?.level }
        return levels.max()
    }

    func isChecking(_ alarm: Alarm) -> Bool {
        Indicator.from(alarm).contains { ind in inProgress.contains(ind.id) || queued.contains(ind) }
    }

    // MARK: Checking

    /// Checks an alarm's IP and domain now (moves them to the front of the queue).
    func check(_ alarm: Alarm, force: Bool = true) {
        for ind in Indicator.from(alarm).reversed() { enqueue(ind, force: force, front: true) }
    }

    /// Called after each refresh: checks security alarms that arrived since the last refresh.
    func didRefresh(activeAlarms: [Alarm]) {
        let ids = Set(activeAlarms.map(\.id))
        guard let seen = autoSeenAlarmIDs else {
            // First run: only alarms that arrive from now on are "new"
            saveAutoSeen(ids)
            return
        }
        let new = activeAlarms.filter { !seen.contains($0.id) && AlarmType.isSecurity($0.type) }
        saveAutoSeen(seen.intersection(ids).union(ids))
        guard autoCheck, isConfigured, !new.isEmpty else { return }
        log.notice("Auto-checking \(new.count, privacy: .public) new security alarm(s)")
        for alarm in new.sorted(by: { $0.ts > $1.ts }).prefix(25) {
            for ind in Indicator.from(alarm) { enqueue(ind, force: false, front: false, notify: true) }
        }
    }

    private var notifyIDs: Set<String> = []

    private func enqueue(_ ind: Indicator, force: Bool, front: Bool, notify: Bool = false) {
        guard isConfigured else { return }
        if !force, let r = reports[ind.id], Date().timeIntervalSince(r.checkedAt) < Self.cacheTTL, !r.hasErrors { return }
        if notify { notifyIDs.insert(ind.id) }
        if inProgress.contains(ind.id) { return }
        if let i = queued.firstIndex(of: ind) {
            guard front else { return }
            queued.remove(at: i)
        }
        if front { queued.insert(ind, at: 0) } else { queued.append(ind) }
        processQueue()
    }

    private func processQueue() {
        guard worker == nil, !queued.isEmpty else { return }
        worker = Task { [weak self] in
            while let self, let ind = self.queued.first {
                self.queued.removeFirst()
                self.inProgress.insert(ind.id)
                await self.run(ind)
                self.inProgress.remove(ind.id)
            }
            self?.worker = nil
        }
    }

    private func run(_ ind: Indicator) async {
        var results: [ServiceResult] = []
        for service in activeServices where service.supports(ind.kind) {
            results.append(await lookup(service, ind))
        }
        guard !results.isEmpty else { return }
        let report = ReputationReport(indicator: ind, checkedAt: Date(), results: results)
        reports[ind.id] = report
        saveCache()
        log.notice("Checked \(ind.kind.rawValue, privacy: .public): \(report.level.label, privacy: .public)")
        if notifyIDs.remove(ind.id) != nil, report.level == .malicious { notifyMalicious(report) }
    }

    private func lookup(_ service: ThreatService, _ ind: Indicator) async -> ServiceResult {
        func failed(_ message: String) -> ServiceResult {
            ServiceResult(service: service, level: .unknown, summary: message, error: message)
        }
        if let until = pausedUntil[service], until > Date() {
            return failed("Paused after a rate limit; retry \(Fmt.relative(until))")
        }
        if let cap = service.dailyLimit, usage(service) + service.requestsPerLookup > cap {
            return failed("Daily limit of \(cap) lookups reached")
        }
        // Space requests out to respect the per-minute limits
        if let last = lastRequest[service] {
            let wait = service.minInterval - Date().timeIntervalSince(last)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        lastRequest[service] = Date()
        countUsage(service)
        do {
            return try await client.lookup(service, ind, key: keys[service] ?? "")
        } catch ThreatIntelError.rateLimited(let retry) {
            pausedUntil[service] = Date().addingTimeInterval(retry ?? 60)
            return failed(ThreatIntelError.rateLimited(retryAfter: retry).localizedDescription)
        } catch {
            return failed(error.localizedDescription)
        }
    }

    // MARK: Notifications

    private func notifyMalicious(_ report: ReputationReport) {
        guard Store.shared.notifyNewAlarms, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Malicious \(report.indicator.kind == .ip ? "IP" : "domain") in a security alarm"
        let who = report.results.filter { $0.level == .malicious }.map(\.service.name).joined(separator: ", ")
        content.body = "\(report.indicator.value) is flagged by \(who). Open FirewallaDock to review and block it."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "reputation-\(report.indicator.id)", content: content, trigger: nil)
        )
    }

    // MARK: Usage (daily counters, reset at 00:00 UTC like VirusTotal's quota)

    private static var today: String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: Date())
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }

    /// Lookups used today (read-only, safe to call from a view).
    func usage(_ s: ThreatService) -> Int {
        UserDefaults.standard.string(forKey: "threatIntelUsageDay") == Self.today ? (usedToday[s] ?? 0) : 0
    }

    private func countUsage(_ s: ThreatService) {
        let d = UserDefaults.standard
        if d.string(forKey: "threatIntelUsageDay") != Self.today {
            usedToday = [:]
            d.set(Self.today, forKey: "threatIntelUsageDay")
        }
        usedToday[s, default: 0] += s.requestsPerLookup
        d.set(Dictionary(uniqueKeysWithValues: usedToday.map { ($0.key.rawValue, $0.value) }), forKey: "threatIntelUsage")
    }

    private func loadUsage() {
        let d = UserDefaults.standard
        guard d.string(forKey: "threatIntelUsageDay") == Self.today,
              let raw = d.dictionary(forKey: "threatIntelUsage") as? [String: Int] else { return }
        for (k, v) in raw { if let s = ThreatService(rawValue: k) { usedToday[s] = v } }
    }

    private func saveAutoSeen(_ ids: Set<String>) {
        autoSeenAlarmIDs = ids
        UserDefaults.standard.set(Array(ids), forKey: "threatIntelAutoSeen")
    }

    // MARK: Cache (Application Support inside the app's sandbox container)

    private var cacheURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reputation-cache.json")
    }

    private func loadCache() {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([ReputationReport].self, from: data) else { return }
        // Keep a week of results so verdicts stay visible; anything older than a day is re-checked when needed
        let fresh = list.filter { Date().timeIntervalSince($0.checkedAt) < 7 * 24 * 3600 }
        reports = Dictionary(fresh.map { ($0.indicator.id, $0) }, uniquingKeysWith: { a, b in a.checkedAt > b.checkedAt ? a : b })
    }

    private func saveCache() {
        guard let url = cacheURL, let data = try? JSONEncoder().encode(Array(reports.values)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
