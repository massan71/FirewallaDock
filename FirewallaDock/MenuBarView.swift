import SwiftUI

/// Icon (and optional alarm count) shown in the macOS menu bar.
struct MenuBarLabel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let count = store.badgeCount
        HStack(spacing: 3) {
            Image(systemName: store.hasProblem ? "exclamationmark.shield.fill" : "shield.lefthalf.filled")
            if store.menuBarShowsCount && count > 0 {
                Text("\(count)").monospacedDigit()
            }
        }
    }
}

/// Compact panel with the essential data, opened from the menu bar icon.
struct MenuBarView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !store.isConfigured {
                Text("Not configured. Open Settings to enter your MSP URL and API token.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                if let err = store.errorMessage {
                    HStack(alignment: .top) {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                        Spacer(minLength: 4)
                        Button {
                            store.dismissError()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                    }
                }
                boxes
                stats
                recentAlarms
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Firewalla").font(.headline)
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.small)
            } else if let last = store.lastUpdated {
                Text("Updated \(Fmt.relative(last))").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                store.manualRefresh(from: "menu bar")
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .disabled(store.isLoading || !store.isConfigured)
        }
    }

    private var boxes: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.boxes) { box in
                HStack(spacing: 8) {
                    Circle().fill(box.online ? .green : .red).frame(width: 8, height: 8)
                    Text(box.name)
                    Spacer()
                    Text(box.online ? "Online" : "Offline")
                        .font(.caption)
                        .foregroundStyle(box.online ? Color.secondary : Color.red)
                }
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 8) {
            MiniStat(value: "\(store.activeAlarms.count)", title: "Alarms",
                     tint: store.activeAlarms.isEmpty ? .green : .orange)
            MiniStat(value: "\(store.securityAlarmCount)", title: "Security",
                     tint: store.securityAlarmCount == 0 ? .green : .red)
            MiniStat(value: "\(store.onlineDevices)/\(store.devices.count)", title: "Devices online",
                     tint: .primary)
        }
    }

    @ViewBuilder
    private var recentAlarms: some View {
        let recent = Array(store.activeAlarms.prefix(5))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent alarms").font(.subheadline.weight(.semibold))
                ForEach(recent) { alarm in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: AlarmType.icon(alarm.type))
                            .foregroundStyle(AlarmType.isSecurity(alarm.type) ? .red : .orange)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(alarm.message).font(.caption).lineLimit(2)
                            Text(Fmt.relative(alarm.date)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open FirewallaDock") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            // Without a Dock icon the app isn't active, so bring the Settings window to the front
            .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit FirewallaDock")
        }
    }
}

private struct MiniStat: View {
    let value: String
    let title: String
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).foregroundStyle(tint)
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}
