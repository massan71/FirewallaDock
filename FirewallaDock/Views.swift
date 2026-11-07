import Charts
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Panoramica"
    case alarms = "Allarmi"
    case devices = "Dispositivi"
    case flows = "Flussi"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .alarms: return "bell.badge"
        case .devices: return "laptopcomputer.and.iphone"
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
                    ErrorBanner(message: err)
                }
                if !store.isConfigured {
                    OnboardingView()
                } else {
                    switch selection ?? .overview {
                    case .overview: OverviewView()
                    case .alarms: AlarmsView()
                    case .devices: DevicesView()
                    case .flows: FlowsView()
                    }
                }
            }
            .navigationTitle(selection?.rawValue ?? "Firewalla")
            .toolbar {
                ToolbarItemGroup {
                    if let last = store.lastUpdated {
                        Text("Aggiornato \(last.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await store.refresh() }
                    } label: { Label("Aggiorna", systemImage: "arrow.clockwise") }
                    .disabled(store.isLoading)
                    SettingsLink { Label("Impostazioni", systemImage: "gearshape") }
                }
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }
}

struct OnboardingView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Collega il tuo Firewalla", systemImage: "network.badge.shield.half.filled")
        } description: {
            Text("Crea un token in Firewalla MSP → Settings → MSP API → Create New Token, poi inseriscilo nelle Impostazioni insieme all'URL del tuo dominio MSP.")
        } actions: {
            SettingsLink { Text("Apri Impostazioni") }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Panoramica

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
                    StatCard(title: "Box online", value: "\(store.onlineBoxes)/\(store.boxes.count)",
                             icon: "shield.lefthalf.filled",
                             tint: store.onlineBoxes == store.boxes.count ? .green : .red)
                    StatCard(title: "Dispositivi online", value: "\(store.onlineDevices)/\(store.devices.count)",
                             icon: "laptopcomputer.and.iphone")
                    StatCard(title: "Allarmi attivi", value: "\(store.activeAlarms.count)",
                             icon: "bell.fill", tint: store.activeAlarms.isEmpty ? .green : .orange)
                    StatCard(title: "Allarmi di sicurezza",
                             value: "\(store.activeAlarms.filter { AlarmType.isSecurity($0.type) }.count)",
                             icon: "exclamationmark.shield.fill", tint: .red)
                }

                Text("Box").font(.title3.bold())
                ForEach(store.boxes) { box in BoxRow(box: box) }

                HStack(alignment: .top, spacing: 16) {
                    TrendChart(title: "Allarmi al giorno", points: store.alarmTrend, color: .orange)
                    TrendChart(title: "Flussi bloccati al giorno", points: store.flowTrend, color: .red)
                }

                if !store.activeAlarms.isEmpty {
                    Text("Allarmi per tipo").font(.title3.bold())
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
            if points.isEmpty {
                Text("Nessun dato").foregroundStyle(.secondary).frame(height: 160)
            } else {
                Chart(points) {
                    BarMark(x: .value("Giorno", $0.date, unit: .day), y: .value("Valore", $0.value))
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
            BarMark(x: .value("Numero", item.count), y: .value("Tipo", item.name))
                .foregroundStyle(Color.orange.gradient)
                .annotation(position: .trailing) { Text("\(item.count)").font(.caption) }
        }
        .frame(height: CGFloat(max(1, grouped.count)) * 28 + 20)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}

// MARK: - Allarmi

struct AlarmsView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var typeFilter = 0
    @State private var selection: Alarm.ID?

    var filtered: [Alarm] {
        store.activeAlarms.filter { a in
            (typeFilter == 0 || a.type == typeFilter) &&
            (search.isEmpty || a.message.localizedCaseInsensitiveContains(search)
                || a.deviceName.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        let presentTypes = Set(store.activeAlarms.map(\.type))
        Table(filtered, selection: $selection) {
            TableColumn("") { a in
                Image(systemName: AlarmType.icon(a.type))
                    .foregroundStyle(AlarmType.isSecurity(a.type) ? .red : .orange)
            }.width(22)
            TableColumn("Quando") { a in
                Text(Fmt.relative(a.date)).help(Fmt.dateTime(a.date))
            }.width(min: 80, ideal: 100)
            TableColumn("Tipo") { a in Text(a.typeName) }.width(min: 110, ideal: 150)
            TableColumn("Messaggio") { a in Text(a.message).help(a.message) }
            TableColumn("Dispositivo") { a in Text(a.deviceName) }.width(min: 90, ideal: 140)
            TableColumn("Remoto") { a in
                Text([a.remote?.domain ?? a.remote?.ip, a.remote?.region].compactMap { $0 }.joined(separator: " · "))
            }.width(min: 90, ideal: 160)
        }
        .contextMenu(forSelectionType: Alarm.ID.self) { ids in
            if let id = ids.first, let alarm = store.alarms.first(where: { $0.id == id }) {
                Button("Copia messaggio") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(alarm.message, forType: .string)
                }
                Button("Archivia allarme") { Task { await store.archive(alarm) } }
            }
        }
        .searchable(text: $search, prompt: "Cerca negli allarmi")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Tipo", selection: $typeFilter) {
                    Text("Tutti i tipi").tag(0)
                    ForEach(AlarmType.all.filter { presentTypes.contains($0.0) }, id: \.0) { t in
                        Text(t.1).tag(t.0)
                    }
                }
                .frame(width: 200)
            }
        }
        .overlay {
            if store.activeAlarms.isEmpty && !store.isLoading {
                ContentUnavailableView("Nessun allarme attivo", systemImage: "checkmark.shield")
            }
        }
    }
}

// MARK: - Dispositivi

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
            TableColumn("Nome", value: \.name)
            TableColumn("IP", value: \.ip) { d in
                HStack(spacing: 4) {
                    Text(d.ip).monospacedDigit()
                    if d.ipReserved { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                }
            }.width(min: 100, ideal: 120)
            TableColumn("MAC", value: \.id) { d in Text(d.id).font(.system(.body, design: .monospaced)) }
                .width(min: 130, ideal: 150)
            TableColumn("Produttore", value: \.macVendor)
            TableColumn("Rete", value: \.networkName).width(min: 70, ideal: 100)
            TableColumn("↓ Download", value: \.totalDownload) { d in Text(Fmt.bytes(d.totalDownload)).monospacedDigit() }
                .width(min: 80, ideal: 90)
            TableColumn("↑ Upload", value: \.totalUpload) { d in Text(Fmt.bytes(d.totalUpload)).monospacedDigit() }
                .width(min: 80, ideal: 90)
            TableColumn("Visto", value: \.lastSeenSort) { d in
                Text(d.lastSeen.map { Fmt.relative($0.asDate) } ?? "—")
            }.width(min: 70, ideal: 90)
        }
        .searchable(text: $search, prompt: "Nome, IP, MAC, produttore")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Toggle("Solo online", isOn: $onlineOnly).toggleStyle(.checkbox)
            }
        }
    }
}

// MARK: - Flussi

struct FlowsView: View {
    @EnvironmentObject var store: Store
    @State private var mode = 0 // 0 tutti, 1 bloccati
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
                    Text("Tutti").tag(0)
                    Text("Bloccati").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                TextField("Query avanzata (es. device.name:*iphone* category:video)", text: $customQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { reload() }
                Button("Cerca") { reload() }
                if store.isLoadingFlows { ProgressView().controlSize(.small) }
            }
            .padding(10)

            if let err = store.flowsError { ErrorBanner(message: err) }

            Table(store.flows.sorted(using: sortOrder), sortOrder: $sortOrder) {
                TableColumn("", value: \.tsSort) { f in
                    Image(systemName: f.block ? "hand.raised.fill" : "checkmark.circle")
                        .foregroundStyle(f.block ? .red : .green)
                }.width(20)
                TableColumn("Quando", value: \.tsSort) { f in Text(Fmt.relative(f.date)).help(Fmt.dateTime(f.date)) }
                    .width(min: 80, ideal: 90)
                TableColumn("Dispositivo", value: \.deviceName)
                TableColumn("Destinazione", value: \.destinationName)
                TableColumn("Categoria", value: \.categoryName).width(min: 70, ideal: 90)
                TableColumn("Paese", value: \.regionName).width(50)
                TableColumn("Traffico", value: \.total) { f in
                    Text(f.block ? "\(f.count ?? 1)×" : Fmt.bytes(f.total)).monospacedDigit()
                }.width(min: 70, ideal: 80)
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

// MARK: - Impostazioni

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var tokenDraft = ""
    @State private var urlDraft = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Connessione Firewalla MSP") {
                TextField("URL base API", text: $urlDraft, prompt: Text("https://tuodominio.firewalla.net"))
                Text("Usa https://<tuodominio>.firewalla.net oppure https://firewalla.net/api")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("Token API", text: $tokenDraft)
                Text("MSP → Settings → MSP API → Create New Token. \"Read Only\" basta per la lettura; \"Full Access\" serve per archiviare gli allarmi. Il token è salvato nel Portachiavi.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Salva e verifica") {
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

            Section("Comportamento") {
                Picker("Aggiorna ogni", selection: $store.refreshMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                Toggle("Notifica i nuovi allarmi", isOn: $store.notifyNewAlarms)
                Toggle("Badge nel Dock solo per allarmi di sicurezza", isOn: $store.badgeSecurityOnly)
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

