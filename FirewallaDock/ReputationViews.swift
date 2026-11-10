import SwiftUI

extension ThreatLevel {
    var color: Color {
        switch self {
        case .unknown: return .secondary
        case .clean: return .green
        case .suspicious: return .orange
        case .malicious: return .red
        }
    }
}

/// Compact verdict shown in the Alarms table.
struct ReputationBadge: View {
    let alarm: Alarm
    @ObservedObject private var intel = ThreatIntel.shared

    var body: some View {
        if intel.isChecking(alarm) {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Checking").foregroundStyle(.secondary)
            }
        } else if let level = intel.level(for: alarm) {
            Label(level.label, systemImage: level.icon)
                .foregroundStyle(level.color)
        } else if Indicator.from(alarm).isEmpty {
            Text("—").foregroundStyle(.tertiary).help("No public IP or domain to check")
        } else {
            Text("Not checked").foregroundStyle(.tertiary)
        }
    }
}

/// Per-service results for an alarm's IP and domain, with block shortcuts.
struct ReputationSheet: View {
    let alarm: Alarm
    let onBlock: (AlarmAction) -> Void
    @ObservedObject private var intel = ThreatIntel.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let indicators = Indicator.from(alarm)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(alarm.typeName, systemImage: AlarmType.icon(alarm.type)).font(.headline)
                Spacer()
                Text(Fmt.dateTime(alarm.date)).font(.caption).foregroundStyle(.secondary)
            }
            Text(alarm.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)

            if !intel.isConfigured {
                Text("No reputation service is set up. Enable one in Settings → Threat Intelligence.")
                    .font(.callout).foregroundStyle(.orange)
            } else if indicators.isEmpty {
                Text("This alarm has no public IP or domain to check.").font(.callout)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(indicators) { ind in indicatorSection(ind) }
                }
            }
            .frame(minHeight: 120, maxHeight: 420)

            Text("Only the remote IP or domain is sent to the services, never data about your devices.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                let blocks = AlarmAction.blockOptions(for: alarm)
                if !blocks.isEmpty {
                    Menu("Block") {
                        ForEach(blocks) { action in
                            Button(action.menuTitle) {
                                dismiss()
                                onBlock(action)
                            }
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                Button("Check Again") { intel.check(alarm, force: true) }
                    .disabled(!intel.isConfigured || indicators.isEmpty || intel.isChecking(alarm))
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func indicatorSection(_ ind: Indicator) -> some View {
        let report = intel.report(for: ind)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ind.kind == .ip ? "IP" : "Domain").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(ind.value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Spacer()
                if intel.inProgress.contains(ind.id) || intel.queued.contains(ind) {
                    ProgressView().controlSize(.small)
                } else if let report {
                    Label(report.level.label, systemImage: report.level.icon)
                        .foregroundStyle(report.level.color).font(.callout.weight(.semibold))
                }
            }
            if let report {
                ForEach(report.results) { result in resultRow(result) }
                Text("Checked \(Fmt.relative(report.checkedAt))").font(.caption2).foregroundStyle(.tertiary)
            } else if !intel.inProgress.contains(ind.id) && !intel.queued.contains(ind) {
                Text("Not checked yet").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }

    private func resultRow(_ r: ServiceResult) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: r.error != nil ? "exclamationmark.circle" : r.level.icon)
                .foregroundStyle(r.error != nil ? Color.secondary : r.level.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(r.service.name).font(.callout.weight(.medium))
                    Text(r.summary).font(.callout).foregroundStyle(r.error != nil ? .secondary : .primary)
                }
                ForEach(r.details, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let link = r.link {
                Link(destination: link) { Image(systemName: "arrow.up.right.square") }
                    .help("Open in \(r.service.name)")
            }
        }
    }
}

/// Settings section for the reputation services.
struct ThreatIntelSettings: View {
    @ObservedObject private var intel = ThreatIntel.shared
    @State private var keyDrafts: [ThreatService: String] = [:]

    var body: some View {
        Section {
            ForEach(ThreatService.allCases) { service in serviceRow(service) }
            Toggle("Automatically check new security alarms", isOn: $intel.autoCheck)
            Text("Only the remote IP or domain of an alarm is sent, never local addresses or data about your devices. Checks respect each service's free limits; results are kept for 24 hours.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear Saved Results") { intel.clearCache() }
        } header: {
            Text("Threat Intelligence")
        }
        .onAppear {
            for s in ThreatService.allCases where s.needsKey { keyDrafts[s] = intel.keys[s] ?? "" }
        }
    }

    @ViewBuilder
    private func serviceRow(_ service: ThreatService) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(service.name, isOn: Binding(
                    get: { intel.enabled.contains(service) },
                    set: { on in
                        if on { intel.enabled.insert(service) } else { intel.enabled.remove(service) }
                    }
                ))
                .disabled(service.needsKey && (intel.keys[service] ?? "").isEmpty)
                Spacer()
                if let cap = service.dailyLimit {
                    Text("\(intel.usage(service))/\(cap) today").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else if intel.usage(service) > 0 {
                    Text("\(intel.usage(service)) today").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(service.info).font(.caption).foregroundStyle(.secondary)
            if service.needsKey {
                HStack {
                    SecureField("API key", text: Binding(
                        get: { keyDrafts[service] ?? "" },
                        set: { keyDrafts[service] = $0 }
                    ))
                    .onSubmit { save(service) }
                    Button("Save") { save(service) }
                        .disabled((keyDrafts[service] ?? "") == (intel.keys[service] ?? ""))
                    if let url = service.keyURL {
                        Link("Get a key", destination: url).font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func save(_ service: ThreatService) {
        let key = keyDrafts[service] ?? ""
        intel.setKey(key, for: service)
        // Saving a key turns the service on; removing it turns it off
        if !key.isEmpty { intel.enabled.insert(service) }
    }
}
