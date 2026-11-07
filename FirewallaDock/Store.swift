import AppKit
import Foundation
import UserNotifications

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    // Impostazioni
    @Published var baseURL: String { didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") } }
    @Published var token: String { didSet { Keychain.save(token) } }
    @Published var refreshMinutes: Int { didSet { UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes"); restartTimer() } }
    @Published var notifyNewAlarms: Bool { didSet { UserDefaults.standard.set(notifyNewAlarms, forKey: "notifyNewAlarms"); if notifyNewAlarms { requestNotificationPermission() } } }
    @Published var badgeSecurityOnly: Bool { didSet { UserDefaults.standard.set(badgeSecurityOnly, forKey: "badgeSecurityOnly"); updateDock() } }

    // Dati
    @Published var boxes: [Box] = []
    @Published var devices: [Device] = []
    @Published var alarms: [Alarm] = []
    @Published var alarmTrend: [TrendPoint] = []
    @Published var flowTrend: [TrendPoint] = []
    @Published var flows: [Flow] = []

    // Stato
    @Published var isLoading = false
    @Published var isLoadingFlows = false
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var flowsError: String?

    private var timerTask: Task<Void, Never>?
    private var seenAlarmIDs: Set<String>?

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
    }

    // MARK: Ciclo di aggiornamento

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

        var errors: [String] = []
        do { boxes = try await b.sorted { $0.name < $1.name } } catch { errors.append("Box: \(error.localizedDescription)") }
        do { devices = try await d } catch { errors.append("Dispositivi: \(error.localizedDescription)") }
        do {
            let fetched = try await a
            notifyNew(fetched)
            alarms = fetched.sorted { $0.ts > $1.ts }
        } catch { errors.append("Allarmi: \(error.localizedDescription)") }
        // I trend sono opzionali: se non disponibili non segnaliamo errore
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

    func archive(_ alarm: Alarm) async {
        do {
            try await api.archive(alarm)
            alarms.removeAll { $0.id == alarm.id }
            updateDock()
        } catch {
            errorMessage = "Archiviazione non riuscita: \(error.localizedDescription) (serve un token Full Access)"
        }
    }

    func testConnection() async -> String {
        do {
            let b = try await api.boxes()
            return "✅ Connesso: \(b.count) box trovati (\(b.map(\.name).joined(separator: ", ")))"
        } catch {
            return "❌ \(error.localizedDescription)"
        }
    }

    // MARK: Dock

    func updateDock() {
        let count = badgeCount
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : (errorMessage != nil && isConfigured ? "!" : nil)
    }

    // MARK: Notifiche

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notifyNew(_ fetched: [Alarm]) {
        let ids = Set(fetched.map(\.id))
        defer { seenAlarmIDs = (seenAlarmIDs ?? []).union(ids) }
        // Al primo caricamento non notifichiamo lo storico
        guard let seen = seenAlarmIDs, notifyNewAlarms, canNotify else { return }
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
