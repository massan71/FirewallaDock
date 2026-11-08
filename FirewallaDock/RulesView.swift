import SwiftUI

/// Firewalla rules with a switch to pause or resume each one.
/// The MSP API has no endpoint to toggle box services (ad block, family protection, VPN...),
/// so rules are what the app can turn on and off.
struct RulesView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var statusFilter = 0 // 0 all, 1 active, 2 paused
    @State private var sortOrder = [KeyPathComparator(\Rule.updatedSort, order: .reverse)]

    private var deviceNames: [String: String] {
        Dictionary(store.devices.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }
    private var networkNames: [String: String] {
        var map: [String: String] = [:]
        for d in store.devices {
            if let id = d.network?.id, let name = d.network?.name { map[id] = name }
        }
        return map
    }

    private func scopeDescription(_ rule: Rule) -> String {
        guard let scope = rule.scope, let value = scope.value else { return "All devices" }
        switch scope.type {
        case "device": return deviceNames[value] ?? value
        case "network": return "Network: \(networkNames[value] ?? value)"
        case "group": return "Group \(value)"
        case "user": return "User \(value)"
        default: return "\(scope.type): \(value)"
        }
    }

    private var filtered: [Rule] {
        store.rules.filter { r in
            (statusFilter == 0 || (statusFilter == 1) == r.isActive) &&
            (search.isEmpty
                || r.title.localizedCaseInsensitiveContains(search)
                || r.targetDescription.localizedCaseInsensitiveContains(search)
                || scopeDescription(r).localizedCaseInsensitiveContains(search))
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let err = store.rulesError { ErrorBanner(message: err) }

            Table(filtered, sortOrder: $sortOrder) {
                TableColumn("On", value: \.activeSort) { rule in
                    if store.busyRuleIDs.contains(rule.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Toggle("", isOn: Binding(
                            get: { rule.isActive },
                            set: { newValue in Task { await store.setRule(rule, active: newValue) } }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help(rule.isActive ? "Pause this rule" : "Resume this rule")
                    }
                }.width(44)
                TableColumn("Action", value: \.action) { rule in
                    Label(rule.action.capitalized, systemImage: Rule.actionIcon(rule.action))
                        .foregroundStyle(rule.action == "allow" ? .green : (rule.action == "block" ? .red : .orange))
                }.width(min: 80, ideal: 95)
                TableColumn("Target", value: \.targetDescription) { rule in
                    Text(rule.targetDescription).help(rule.targetDescription)
                }
                TableColumn("Applies to") { rule in Text(scopeDescription(rule)) }
                    .width(min: 100, ideal: 150)
                TableColumn("Notes", value: \.notes) { rule in
                    Text(rule.name ?? rule.notes).foregroundStyle(.secondary).help(rule.notes)
                }
                TableColumn("Hits", value: \.hitSort) { rule in
                    Text(rule.hitCount.map { $0.formatted() } ?? "—")
                        .monospacedDigit()
                        .help(rule.lastHitTs.map { "Last hit \(Fmt.relative($0.asDate))" } ?? "")
                }.width(min: 50, ideal: 70)
                TableColumn("Status", value: \.status) { rule in
                    if rule.isActive {
                        Text("Active")
                    } else if let resume = rule.resumeTs {
                        Text("Paused until \(Fmt.dateTime(resume.asDate))").foregroundStyle(.orange)
                    } else {
                        Text("Paused").foregroundStyle(.orange)
                    }
                }.width(min: 70, ideal: 120)
            }
            .searchable(text: $search, prompt: "Search rules")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Picker("Status", selection: $statusFilter) {
                        Text("All").tag(0)
                        Text("Active").tag(1)
                        Text("Paused").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }
            .overlay {
                if store.rules.isEmpty && !store.isLoading && store.rulesError == nil {
                    ContentUnavailableView("No rules", systemImage: "list.bullet.rectangle",
                                           description: Text("Rules created in the Firewalla app or MSP appear here."))
                }
            }

            Text("Pausing or resuming a rule requires a Full Access API token. Box services such as ad block or family protection can't be switched through the MSP API.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}
