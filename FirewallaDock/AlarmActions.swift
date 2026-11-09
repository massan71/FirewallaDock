import Foundation

/// A "mute" or "block" action that can be taken from an alarm.
///
/// - Mute calls `POST /v2/alarms/:gid/:aid/mute`: Firewalla archives the alarm and stops creating
///   new alarms that match the target and scope. Alarms that already exist stay active.
/// - Block calls `POST /v2/rules` to create a block rule for the alarm's remote domain or IP.
struct AlarmAction: Identifiable, Hashable {
    enum Kind { case mute, block }

    let kind: Kind
    let alarm: Alarm
    /// `alarmType`, `domain` or `ip`
    let targetType: String
    let targetValue: String?
    /// Device (MAC) the action is limited to; nil means all devices.
    let deviceID: String?
    let deviceName: String?

    var id: String { "\(kind)|\(targetType)|\(targetValue ?? "")|\(deviceID ?? "*")" }

    private var targetLabel: String {
        targetType == "alarmType" ? "“\(alarm.typeName)” alarms" : (targetValue ?? "")
    }
    private var deviceLabel: String { deviceName ?? deviceID ?? "this device" }

    /// Short title for the context menu.
    var menuTitle: String {
        switch (kind, deviceID) {
        case (.mute, nil) where targetType == "alarmType": return "All \(targetLabel)"
        case (.mute, nil): return "Alarms for \(targetLabel)"
        case (.mute, _) where targetType == "alarmType": return "\(targetLabel) from \(deviceLabel)"
        case (.mute, _): return "Alarms for \(targetLabel) from \(deviceLabel)"
        case (.block, nil): return "Block \(targetLabel) on All Devices"
        case (.block, _): return "Block \(targetLabel) on \(deviceLabel)"
        }
    }

    var confirmTitle: String {
        switch kind {
        case .mute: return "Mute \(menuTitle.prefix(1).lowercased() + menuTitle.dropFirst())?"
        case .block: return "\(menuTitle)?"
        }
    }

    var confirmMessage: String {
        switch kind {
        case .mute:
            return "Firewalla will stop creating these alarms and archives this one. Alarms that already exist stay active unless you archive them too. Requires a Full Access API token."
        case .block:
            return "Creates a block rule in Firewalla. You can pause it later in Rules. Requires a Full Access API token."
        }
    }

    var verb: String { kind == .mute ? "Mute" : "Block" }

    /// API target and scope for this action.
    var target: APIPart { APIPart(type: targetType, value: targetValue) }
    var muteScope: APIPart { deviceID.map { APIPart(type: "device", value: $0) } ?? APIPart(type: "all", value: nil) }
    var ruleScope: APIPart? { deviceID.map { APIPart(type: "device", value: $0) } }

    var ruleNotes: String {
        let on = deviceID == nil ? "all devices" : deviceLabel
        return "Blocked from FirewallaDock (\(alarm.typeName) alarm, \(on))"
    }

    /// Whether an existing alarm is covered by this action (used to offer archiving it too).
    func matches(_ other: Alarm) -> Bool {
        if let deviceID, other.device?.id != deviceID { return false }
        switch targetType {
        case "alarmType": return other.type == alarm.type
        case "domain": return other.remote?.domain == targetValue
        case "ip": return other.remote?.ip == targetValue
        default: return false
        }
    }

    // MARK: Options for an alarm

    static func muteOptions(for alarm: Alarm) -> [AlarmAction] {
        var options: [AlarmAction] = []
        let device = alarm.device?.id
        let name = alarm.device?.name ?? alarm.device?.ip

        func add(_ type: String, _ value: String?) {
            options.append(AlarmAction(kind: .mute, alarm: alarm, targetType: type, targetValue: value, deviceID: nil, deviceName: nil))
            if let device {
                options.append(AlarmAction(kind: .mute, alarm: alarm, targetType: type, targetValue: value, deviceID: device, deviceName: name))
            }
        }
        add("alarmType", nil)
        if let remote = remoteTarget(alarm) { add(remote.type, remote.value) }
        return options
    }

    static func blockOptions(for alarm: Alarm) -> [AlarmAction] {
        guard let remote = remoteTarget(alarm) else { return [] }
        var options = [AlarmAction(kind: .block, alarm: alarm, targetType: remote.type, targetValue: remote.value, deviceID: nil, deviceName: nil)]
        if let device = alarm.device?.id {
            options.append(AlarmAction(kind: .block, alarm: alarm, targetType: remote.type, targetValue: remote.value,
                                       deviceID: device, deviceName: alarm.device?.name ?? alarm.device?.ip))
        }
        return options
    }

    /// The alarm's remote endpoint: its domain when known, otherwise its IP.
    private static func remoteTarget(_ alarm: Alarm) -> (type: String, value: String)? {
        if let domain = alarm.remote?.domain, !domain.isEmpty { return ("domain", domain) }
        if let ip = alarm.remote?.ip, !ip.isEmpty { return ("ip", ip) }
        return nil
    }
}
