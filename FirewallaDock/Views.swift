import Charts
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case alarms = "Alarms"
    case devices = "Devices"
    case rules = "Rules"
    case flows = "Flows"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .alarms: return "bell.badge"
        case .devices: return "laptopcomputer.and.iphone"
        case .rules: return "list.bullet.rectangle"
        case .flows: return "arrow.left.arrow.right"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .badge(item == .alarms ? store.activeAlarms.count : 0)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                if let err = store.errorMessage {
                    ErrorBanner(message: err) { store.dismissError() }
                }
                if !store.isConfigured {
                    OnboardingView()
                } else {
                    switch selection ?? .overview {
                    case .overview: OverviewView()
                    case .alarms: AlarmsView()
                    case .devices: DevicesView()
                    case .rules: RulesView()
                    case .flows: FlowsView()
                    }
                }
            }
            .navigationTitle(selection?.rawValue ?? "Firewalla")
            .toolbar {
                ToolbarItemGroup {
                    if let last = store.lastUpdated {
                        Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await store.refresh() }
                    } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.isLoading)
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                }
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }
}

struct OnboardingView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Connect your Firewalla", systemImage: "network.badge.shield.half.filled")
        } description: {
            Text("Create a token in Firewalla MSP → Settings → MSP API → Create New Token, then enter it in Settings together with your MSP domain URL.")
        } actions: {
            SettingsLink { Text("Open Settings") }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Overview

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}

struct OverviewView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    StatCard(title: "Boxes online", value: "\(store.onlineBoxes)/\(store.boxes.count)",
                             icon: "shield.lefthalf.filled",
                             tint: store.onlineBoxes == store.boxes.count ? .green : .red)
                    StatCard(title: "Devices online", value: "\(store.onlineDevices)/\(store.devices.count)",
                             icon: "laptopcomputer.and.iphone")
                    StatCard(title: "Active alarms", value: "\(store.activeAlarms.count)",
                             icon: "bell.fill", tint: store.activeAlarms.isEmpty ? .green : .orange)
                    StatCard(title: "Security alarms",
                             value: "\(store.activeAlarms.filter { AlarmType.isSecurity($0.type) }.count)",
                             icon: "exclamationmark.shield.fill", tint: .red)
                }

                Text("Boxes").font(.title3.bold())
                ForEach(store.boxes) { box in BoxRow(box: box) }

                HStack(alignment: .top, spacing: 16) {
                    TrendChart(title: "Alarms per day", points: store.alarmTrend, color: .orange)
                    TrendChart(title: "Blocked flows per day", points: store.flowTrend, color: .red)
                }

                if !store.activeAlarms.isEmpty {
                    Text("Alarms by type").font(.title3.bold())
                    AlarmTypeChart(alarms: store.activeAlarms)
                }
            }
            .padding(20)
        }
    }
}

struct BoxRow: View {
    let box: Box
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(box.online ? .green : .red).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(box.name).font(.headline)
                Text([box.model?.capitalized, box.mode, box.version.map { "v\($0)" }, box.publicIP]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label("\(box.deviceCount)", systemImage: "laptopcomputer.and.iphone")
            Label("\(box.ruleCount)", systemImage: "list.bullet.rectangle")
            Label("\(box.alarmCount)", systemImage: "bell")
        }
        .font(.callout)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }
}

struct TrendChart: View {
    let title: String
    let points: [TrendPoint]
    let color: Color

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            if points.isEmpty || points.allSatisfy({ $0.value == 0 }) {
                Text(points.isEmpty ? "No data" : "None in the last \(points.count) days")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart(points) {
                    BarMark(x: .value("Day", $0.date, unit: .day), y: .value("Value", $0.value))
                        .foregroundStyle(color.gradient)
                }
                .frame(height: 160)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}

struct AlarmTypeChart: View {
    let alarms: [Alarm]
    var body: some View {
        let grouped = Dictionary(grouping: alarms, by: \.type)
            .map { (name: AlarmType.name($0.key), count: $0.value.count) }
            .sorted { $0.count > $1.count }
        Chart(grouped, id: \.name) { item in
            BarMark(x: .value("Count", item.count), y: .value("Type", item.name))
                .foregroundStyle(Color.orange.gradient)
                .annotation(position: .trailing) { Text("\(item.count)").font(.caption) }
        }
        .frame(height: CGFloat(max(1, grouped.count)) * 28 + 20)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}

// MARK: - Alarms

struct AlarmsView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var typeFilter = 0
    @State private var seenFilter = 0 // 0 all, 1 new, 2 seen
    @State private var selection = Set<Alarm.ID>()
    @State private var pendingArchive: [Alarm] = []
    @State private var confirmArchive = false

    var filtered: [Alarm] {
        store.activeAlarms.filter { a in
            let seen = store.seenAlarmIDs.contains(a.id)
            return (typeFilter == 0 || a.type == typeFilter) &&
                (seenFilter == 0 || (seenFilter == 2) == seen) &&
                (search.isEmpty || a.message.localizedCaseInsensitiveContains(search)
                    || a.deviceName.localizedCaseInsensitiveContains(search))
        }
    }

    private var selectedAlarms: [Alarm] { store.activeAlarms.filter { selection.contains($0.id) } }

    private func requestArchive(_ alarms: [Alarm]) {
        guard !alarms.isEmpty else { return }
        pendingArchive = alarms
        confirmArchive = true
    }

    var body: some View {
        let presentTypes = Set(store.activeAlarms.map(\.type))
        let seenCount = store.seenActiveAlarms.count
        VStack(spacing: 0) {
            Table(filtered, selection: $selection) {
                TableColumn("") { a in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(store.seenAlarmIDs.contains(a.id) ? Color.clear : Color.blue)
                            .frame(width: 7, height: 7)
                            .help("New")
                        Image(systemName: AlarmType.icon(a.type))
                            .foregroundStyle(AlarmType.isSecurity(a.type) ? .red : .orange)
                    }
                }.width(36)
                TableColumn("When") { a in
                    Text(Fmt.relative(a.date)).help(Fmt.dateTime(a.date))
                }.width(min: 80, ideal: 100)
                TableColumn("Type") { a in Text(a.typeName) }.width(min: 110, ideal: 150)
                TableColumn("Message") { a in
                    Text(a.message)
                        .fontWeight(store.seenAlarmIDs.contains(a.id) ? .regular : .semibold)
                        .help(a.message)
                }
                TableColumn("Device") { a in Text(a.deviceName) }.width(min: 90, ideal: 140)
                TableColumn("Remote") { a in
                    Text([a.remote?.domain ?? a.remote?.ip, a.remote?.region].compactMap { $0 }.joined(separator: " · "))
                }.width(min: 90, ideal: 160)
            }
            .contextMenu(forSelectionType: Alarm.ID.self) { ids in
                let alarms = store.activeAlarms.filter { ids.contains($0.id) }
                if alarms.count == 1, let alarm = alarms.first {
                    Button("Copy Message") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(alarm.message, forType: .string)
                    }
                }
                if !alarms.isEmpty {
                    Button("Mark as Seen") { store.markSeen(ids) }
                    Button(alarms.count == 1 ? "Archive Alarm" : "Archive \(alarms.count) Alarms") {
                        requestArchive(alarms)
                    }
                }
            }
            .onChange(of: selection) { _, ids in store.markSeen(ids) }
            .onDeleteCommand { requestArchive(selectedAlarms) }

            if let progress = store.archiveProgress {
                HStack {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Text("Archiving \(progress.done) of \(progress.total)…").font(.caption).monospacedDigit()
                }
                .padding(8)
            }
        }
        .searchable(text: $search, prompt: "Search alarms")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Picker("Show", selection: $seenFilter) {
                    Text("All").tag(0)
                    Text("New").tag(1)
                    Text("Seen").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Picker("Type", selection: $typeFilter) {
                    Text("All types").tag(0)
                    ForEach(AlarmType.all.filter { presentTypes.contains($0.0) }, id: \.0) { t in
                        Text(t.1).tag(t.0)
                    }
                }
                .frame(width: 180)
            }
            ToolbarItemGroup {
                Button {
                    store.markAllSeen()
                } label: { Label("Mark All as Seen", systemImage: "eye") }
                .help("Mark all alarms as seen")
                .disabled(seenCount == store.activeAlarms.count)

                Button {
                    requestArchive(selectedAlarms)
                } label: { Label("Archive Selected", systemImage: "archivebox") }
                .help("Archive the selected alarms (⌫)")
                .disabled(selection.isEmpty || store.archiveProgress != nil)

                Button {
                    requestArchive(store.seenActiveAlarms)
                } label: { Label("Archive Seen (\(seenCount))", systemImage: "archivebox.fill") }
                .help("Archive every alarm you have already seen")
                .disabled(seenCount == 0 || store.archiveProgress != nil)
            }
        }
        .confirmationDialog(
            pendingArchive.count == 1 ? "Archive this alarm?" : "Archive \(pendingArchive.count) alarms?",
            isPresented: $confirmArchive
        ) {
            Button(pendingArchive.count == 1 ? "Archive" : "Archive \(pendingArchive.count)") {
                let alarms = pendingArchive
                selection.subtract(alarms.map(\.id))
                Task { await store.archive(alarms) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Archived alarms leave the active list but stay available as archived in Firewalla. This requires a Full Access API token.")
        }
        .overlay {
            if store.activeAlarms.isEmpty && !store.isLoading {
                ContentUnavailableView("No active alarms", systemImage: "checkmark.shield")
            } else if filtered.isEmpty {
                ContentUnavailableView.search
            }
        }
    }
}

// MARK: - Devices

struct DevicesView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var onlineOnly = false
    @State private var sortOrder = [KeyPathComparator(\Device.totalDownload, order: .reverse)]

    var filtered: [Device] {
        store.devices.filter { d in
            (!onlineOnly || d.online) &&
            (search.isEmpty || d.name.localizedCaseInsensitiveContains(search)
                || d.ip.contains(search)
                || d.id.localizedCaseInsensitiveContains(search)
                || d.macVendor.localizedCaseInsensitiveContains(search))
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        Table(filtered, sortOrder: $sortOrder) {
            TableColumn("", value: \.onlineSort) { d in
                Circle().fill(d.online ? .green : .gray.opacity(0.5)).frame(width: 8, height: 8)
            }.width(16)
            TableColumn("Name", value: \.name)
            TableColumn("IP", value: \.ip) { d in
                HStack(spacing: 4) {
                    Text(d.ip).monospacedDigit()
                    if d.ipReserved { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                }
            }.width(min: 100, ideal: 120)
            TableColumn("MAC", value: \.id) { d in Text(d.id).font(.system(.body, design: .monospaced)) }
                .width(min: 130, ideal: 150)
            TableColumn("Vendor", value: \.macVendor)
            TableColumn("Network", value: \.networkName).width(min: 70, ideal: 100)
            TableColumn("↓ Download", value: \.totalDownload) { d in Text(Fmt.bytes(d.totalDownload)).monospacedDigit() }
                .width(min: 80, ideal: 90)
            TableColumn("↑ Upload", value: \.totalUpload) { d in Text(Fmt.bytes(d.totalUpload)).monospacedDigit() }
                .width(min: 80, ideal: 90)
            TableColumn("Last Seen", value: \.lastSeenSort) { d in
                if d.online {
                    Text("Online now").foregroundStyle(.green)
                } else {
                    Text(d.lastSeen.map { Fmt.relative($0.asDate) } ?? "—")
                }
            }.width(min: 70, ideal: 90)
        }
        .searchable(text: $search, prompt: "Name, IP, MAC, vendor")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Toggle("Online only", isOn: $onlineOnly).toggleStyle(.checkbox)
            }
        }
    }
}

// MARK: - Flows

struct FlowsView: View {
    @EnvironmentObject var store: Store
    @State private var mode = 0 // 0 all, 1 blocked
    @State private var customQuery = ""
    @State private var sortOrder = [KeyPathComparator(\Flow.tsSort, order: .reverse)]

    var effectiveQuery: String {
        var parts: [String] = []
        if mode == 1 { parts.append("block:true") }
        let q = customQuery.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { parts.append(q) }
        return parts.joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) {
                    Text("All").tag(0)
                    Text("Blocked").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                TextField("Advanced query (e.g. device.name:*iphone* category:video)", text: $customQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { reload() }
                Button("Search") { reload() }
                if store.isLoadingFlows { ProgressView().controlSize(.small) }
            }
            .padding(10)

            if let err = store.flowsError { ErrorBanner(message: err) { store.flowsError = nil } }

            Table(store.flows.sorted(using: sortOrder), sortOrder: $sortOrder) {
                TableColumn("", value: \.tsSort) { f in
                    Image(systemName: f.block ? "hand.raised.fill" : "checkmark.circle")
                        .foregroundStyle(f.block ? .red : .green)
                }.width(20)
                TableColumn("When", value: \.tsSort) { f in Text(Fmt.relative(f.date)).help(Fmt.dateTime(f.date)) }
                    .width(min: 80, ideal: 90)
                TableColumn("Device", value: \.deviceName)
                TableColumn("Destination", value: \.destinationName)
                TableColumn("Category", value: \.categoryName).width(min: 70, ideal: 90)
                TableColumn("Country", value: \.regionName).width(50)
                TableColumn("Traffic", value: \.total) { f in
                    Text(f.block ? "\(f.count ?? 1)×" : Fmt.bytes(f.total)).monospacedDigit()
                }.width(min: 70, ideal: 80)
            }
            .overlay {
                if store.flows.isEmpty && !store.isLoadingFlows && store.flowsError == nil {
                    ContentUnavailableView {
                        Label("No flows", systemImage: "arrow.left.arrow.right")
                    } description: {
                        Text(customQuery.isEmpty && mode == 0
                             ? "The MSP API returned no flows for the last 24 hours. Flow data is a paid feature: it is only available on some Firewalla MSP plans and must be enabled there."
                             : "No flows match this filter in the last 24 hours.")
                    }
                }
            }
        }
        .onAppear { if store.flows.isEmpty { reload() } }
        .onChange(of: mode) { reload() }
    }

    private func reload() {
        let q = effectiveQuery
        Task { await store.loadFlows(query: q) }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var tokenDraft = ""
    @State private var urlDraft = ""
    @State private var testResult: String?
    @State private var testing = false
    @AppStorage(SettingsKey.showMenuBar) private var showMenuBar = true

    var body: some View {
        Form {
            Section("Firewalla MSP Connection") {
                TextField("API base URL", text: $urlDraft, prompt: Text("https://yourdomain.firewalla.net"))
                Text("Use https://<yourdomain>.firewalla.net or https://firewalla.net/api")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("API token", text: $tokenDraft)
                Text("MSP → Settings → MSP API → Create New Token. \"Read Only\" is enough for viewing; \"Full Access\" is required to archive alarms. The token is stored in the Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save and Test") {
                        store.baseURL = urlDraft
                        store.token = tokenDraft
                        testing = true
                        Task {
                            testResult = await store.testConnection()
                            testing = false
                            await store.refresh()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    if testing { ProgressView().controlSize(.small) }
                }
                if let result = testResult { Text(result).font(.callout).textSelection(.enabled) }
            }

            Section("Behavior") {
                Picker("Refresh every", selection: $store.refreshMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                Toggle("Notify about new alarms", isOn: $store.notifyNewAlarms)
                Toggle("Dock badge for security alarms only", isOn: $store.badgeSecurityOnly)
            }

            Section("Menu Bar") {
                Toggle("Show in menu bar", isOn: $showMenuBar)
                Toggle("Show alarm count next to the icon", isOn: $store.menuBarShowsCount)
                    .disabled(!showMenuBar)
                Text("The count follows the Dock badge setting above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
        .onAppear {
            tokenDraft = store.token
            urlDraft = store.baseURL
        }
    }
}

