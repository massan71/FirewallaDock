import AppKit
import Foundation
import UserNotifications

enum SettingsKey {
    static let showMenuBar = "showMenuBar"
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    // Settings
    @Published var baseURL: String { didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") } }
    @Published var token: String { didSet { Keychain.save(token) } }
    @Published var refreshMinutes: Int { didSet { UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes"); restartTimer() } }
    @Published var notifyNewAlarms: Bool { didSet { UserDefaults.standard.set(notifyNewAlarms, forKey: "notifyNewAlarms"); if notifyNewAlarms { requestNotificationPermission() } } }
    @Published var badgeSecurityOnly: Bool { didSet { UserDefaults.standard.set(badgeSecurityOnly, forKey: "badgeSecurityOnly"); updateDock() } }
    @Published var menuBarShowsCount: Bool { didSet { UserDefaults.standard.set(menuBarShowsCount, forKey: "menuBarShowsCount") } }

    // Data
    @Published var boxes: [Box] = []
    @Published var devices: [Device] = []
    @Published var alarms: [Alarm] = []
    @Published var alarmTrend: [TrendPoint] = []
    @Published var flowTrend: [TrendPoint] = []
    @Published var flows: [Flow] = []
    @Published var rules: [Rule] = []

    /// Alarms the user has seen in the app (persisted). Unseen alarms show a blue dot.
    @Published private(set) var seenAlarmIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(seenAlarmIDs), forKey: "seenAlarmIDs") }
    }

    // State
    @Published var isLoading = false
    @Published var isLoadingFlows = false
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var flowsError: String?
    @Published var rulesError: String?
    @Published var busyRuleIDs: Set<String> = []
    @Published var archiveProgress: (done: Int, total: Int)?

    private var timerTask: Task<Void, Never>?
    private var notifiedAlarmIDs: Set<String>?

    var isConfigured: Bool { !baseURL.trimmingCharacters(in: .whitespaces).isEmpty && !token.isEmpty }
    var api: FirewallaAPI { FirewallaAPI(baseURL: baseURL, token: token) }

    var onlineDevices: Int { devices.filter(\.online).count }
    var onlineBoxes: Int { boxes.filter(\.online).count }
    var activeAlarms: [Alarm] { alarms.filter(\.isActive) }
    var badgeCount: Int {
        badgeSecurityOnly ? activeAlarms.filter { AlarmType.isSecurity($0.type) }.count : activeAlarms.count
    }

    private init() {
        let d = UserDefaults.standard
        baseURL = d.string(forKey: "baseURL") ?? "https://firewalla.net/api"
        token = Keychain.load()
        refreshMinutes = d.object(forKey: "refreshMinutes") as? Int ?? 5
        notifyNewAlarms = d.object(forKey: "notifyNewAlarms") as? Bool ?? true
        badgeSecurityOnly = d.bool(forKey: "badgeSecurityOnly")
        menuBarShowsCount = d.object(forKey: "menuBarShowsCount") as? Bool ?? true
        seenAlarmIDs = Set(d.stringArray(forKey: "seenAlarmIDs") ?? [])
    }

    /// True when something needs attention: a box is offline or the last refresh failed.
    var hasProblem: Bool { boxes.contains { !$0.online } || (isConfigured && errorMessage != nil) }
    var securityAlarmCount: Int { activeAlarms.filter { AlarmType.isSecurity($0.type) }.count }
    var seenActiveAlarms: [Alarm] { activeAlarms.filter { seenAlarmIDs.contains($0.id) } }
    var activeRules: Int { rules.filter(\.isActive).count }

    // MARK: Refresh loop

    func start() {
        if notifyNewAlarms { requestNotificationPermission() }
        restartTimer()
    }

    private func restartTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let minutes = max(1, self?.refreshMinutes ?? 5)
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
    }

    func refresh() async {
        guard isConfigured else {
            errorMessage = APIError.notConfigured.errorDescription
            updateDock()
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let api = self.api
        async let b = api.boxes()
        async let d = api.devices()
        async let a = api.alarms(query: "status:active", max: 1000)
        async let at = api.alarmTrend()
        async let ft = api.blockedFlowTrend()
        async let r = api.rules()

        var errors: [String] = []
        do { boxes = try await b.sorted { $0.name < $1.name } } catch { errors.append("Boxes: \(error.localizedDescription)") }
        do { devices = try await d } catch { errors.append("Devices: \(error.localizedDescription)") }
        do {
            let fetched = try await a
            notifyNew(fetched)
            alarms = fetched.sorted { $0.ts > $1.ts }
            // Forget seen IDs of alarms that are no longer active
            let ids = Set(fetched.map(\.id))
            if !seenAlarmIDs.isSubset(of: ids) { seenAlarmIDs.formIntersection(ids) }
        } catch { errors.append("Alarms: \(error.localizedDescription)") }
        do {
            rules = try await r
            rulesError = nil
        } catch {
            rulesError = error.localizedDescription
        }
        // Trends are optional: no error if unavailable
        alarmTrend = (try? await at) ?? []
        flowTrend = (try? await ft) ?? []

        errorMessage = errors.isEmpty ? nil : Array(Set(errors)).sorted().joined(separator: "\n")
        lastUpdated = Date()
        updateDock()
    }

    func loadFlows(query: String) async {
        guard isConfigured else { return }
        isLoadingFlows = true
        defer { isLoadingFlows = false }
        do {
            flows = try await api.flows(query: query.isEmpty ? nil : query, max: 500)
            flowsError = nil
        } catch {
            flowsError = error.localizedDescription
        }
    }

    // MARK: Seen alarms

    func markSeen<S: Sequence>(_ ids: S) where S.Element == String {
        let new = seenAlarmIDs.union(ids)
        if new != seenAlarmIDs { seenAlarmIDs = new }
    }

    func markAllSeen() { markSeen(activeAlarms.map(\.id)) }

    // MARK: Archiving (requires a Full Access token)

    /// Archives the given alarms, 4 requests at a time. Returns how many failed.
    @discardableResult
    func archive(_ toArchive: [Alarm]) async -> Int {
        guard !toArchive.isEmpty, archiveProgress == nil else { return 0 }
        let api = self.api
        archiveProgress = (0, toArchive.count)
        var archived: Set<String> = []
        var lastError: Error?

        await withTaskGroup(of: (String, Error?).self) { group in
            var iterator = toArchive.makeIterator()
            func addNext() {
                guard let alarm = iterator.next() else { return }
                group.addTask {
                    do { try await api.archive(alarm); return (alarm.id, nil) }
                    catch { return (alarm.id, error) }
                }
            }
            for _ in 0..<4 { addNext() }
            for await (id, error) in group {
                if let error { lastError = error } else { archived.insert(id) }
                archiveProgress = ((archiveProgress?.done ?? 0) + 1, toArchive.count)
                // Stop early on permission errors: every other request would fail too
                if case APIError.http(401, _)? = error { group.cancelAll(); break }
                addNext()
            }
        }

        alarms.removeAll { archived.contains($0.id) }
        seenAlarmIDs.subtract(archived)
        archiveProgress = nil
        let failed = toArchive.count - archived.count
        if let lastError, failed > 0 {
            errorMessage = "Could not archive \(failed) of \(toArchive.count) alarm(s): \(lastError.localizedDescription)"
        }
        updateDock()
        return failed
    }

    // MARK: Rules (requires a Full Access token)

    func setRule(_ rule: Rule, active: Bool) async {
        guard !busyRuleIDs.contains(rule.id) else { return }
        busyRuleIDs.insert(rule.id)
        defer { busyRuleIDs.remove(rule.id) }
        do {
            try await api.setRule(rule, active: active)
            if let i = rules.firstIndex(where: { $0.id == rule.id }) {
                rules[i].status = active ? "active" : "paused"
                if active { rules[i].resumeTs = nil }
            }
            rulesError = nil
        } catch {
            rulesError = "Could not \(active ? "resume" : "pause") the rule: \(error.localizedDescription)"
        }
    }

    func testConnection() async -> String {
        do {
            let b = try await api.boxes()
            return "✅ Connected: \(b.count) box(es) found (\(b.map(\.name).joined(separator: ", ")))"
        } catch {
            return "❌ \(error.localizedDescription)"
        }
    }

    // MARK: Dock

    func updateDock() {
        let count = badgeCount
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : (errorMessage != nil && isConfigured ? "!" : nil)
    }

    // MARK: Notifications

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notifyNew(_ fetched: [Alarm]) {
        let ids = Set(fetched.map(\.id))
        defer { notifiedAlarmIDs = (notifiedAlarmIDs ?? []).union(ids) }
        // Do not notify existing alarms on first load
        guard let seen = notifiedAlarmIDs, notifyNewAlarms, canNotify else { return }
        let new = fetched.filter { !seen.contains($0.id) }.prefix(5)
        for alarm in new {
            let content = UNMutableNotificationContent()
            content.title = alarm.typeName
            content.body = alarm.message
            content.sound = AlarmType.isSecurity(alarm.type) ? .default : nil
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: alarm.id, content: content, trigger: nil)
            )
        }
    }
}
