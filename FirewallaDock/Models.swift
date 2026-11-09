import Foundation

// MARK: - Lenient decoding helpers
// The Firewalla API sometimes returns numbers as strings (e.g. lastSeen) and ids as numbers or strings.

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; stringValue = "\(intValue)" }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    func double(_ key: String) -> Double? {
        let k = AnyCodingKey(key)
        if let d = try? decodeIfPresent(Double.self, forKey: k) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: k) { return Double(s) }
        return nil
    }
    func int(_ key: String) -> Int? {
        let k = AnyCodingKey(key)
        if let i = try? decodeIfPresent(Int.self, forKey: k) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: k) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: k) { return Int(s) }
        return nil
    }
    func string(_ key: String) -> String? {
        let k = AnyCodingKey(key)
        if let s = try? decodeIfPresent(String.self, forKey: k) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: k) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: k) { return String(d) }
        return nil
    }
    func bool(_ key: String) -> Bool? {
        let k = AnyCodingKey(key)
        if let b = try? decodeIfPresent(Bool.self, forKey: k) { return b }
        if let i = try? decodeIfPresent(Int.self, forKey: k) { return i != 0 }
        return nil
    }
    func object<T: Decodable>(_ key: String, _ type: T.Type = T.self) -> T? {
        try? decodeIfPresent(T.self, forKey: AnyCodingKey(key))
    }
}

extension Double {
    var asDate: Date { Date(timeIntervalSince1970: self) }
}

// MARK: - Models

struct NamedRef: Decodable, Hashable {
    var id: String?
    var name: String?
    var ip: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        id = c.string("id")
        name = c.string("name")
        ip = c.string("ip")
    }
}

struct Box: Decodable, Identifiable, Hashable {
    var gid: String
    var name: String
    var model: String?
    var mode: String?
    var online: Bool
    var version: String?
    var publicIP: String?
    var location: String?
    var lastSeen: Double?
    var deviceCount: Int
    var ruleCount: Int
    var alarmCount: Int

    var id: String { gid }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        gid = c.string("gid") ?? UUID().uuidString
        name = c.string("name") ?? "Firewalla"
        model = c.string("model")
        mode = c.string("mode")
        online = c.bool("online") ?? false
        version = c.string("version")
        publicIP = c.string("publicIP")
        location = c.string("location")
        lastSeen = c.double("lastSeen")
        deviceCount = c.int("deviceCount") ?? 0
        ruleCount = c.int("ruleCount") ?? 0
        alarmCount = c.int("alarmCount") ?? 0
    }
}

struct Device: Decodable, Identifiable, Hashable {
    var id: String          // MAC
    var gid: String?
    var name: String
    var ip: String
    var macVendor: String
    var online: Bool
    var ipReserved: Bool
    var lastSeen: Double?
    var network: NamedRef?
    var group: NamedRef?
    var totalDownload: Double
    var totalUpload: Double

    var networkName: String { network?.name ?? "" }
    var lastSeenSort: Double { online ? .greatestFiniteMagnitude : (lastSeen ?? 0) }
    var onlineSort: Int { online ? 1 : 0 }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        id = c.string("id") ?? UUID().uuidString
        gid = c.string("gid")
        name = c.string("name") ?? (c.string("id") ?? "Unknown")
        ip = c.string("ip") ?? ""
        macVendor = c.string("macVendor") ?? ""
        online = c.bool("online") ?? false
        ipReserved = c.bool("ipReserved") ?? false
        lastSeen = c.double("lastSeen")
        network = c.object("network")
        group = c.object("group")
        totalDownload = c.double("totalDownload") ?? 0
        totalUpload = c.double("totalUpload") ?? 0
    }
}

struct AlarmRemote: Decodable, Hashable {
    var ip: String?
    var domain: String?
    var region: String?
    var category: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        ip = c.string("ip")
        domain = c.string("domain")
        region = c.string("region")
        category = c.string("category")
    }
}

struct Alarm: Decodable, Identifiable, Hashable {
    var aid: String
    var gid: String
    var type: Int
    var status: Int?
    var message: String
    var ts: Double
    var direction: String?
    var device: NamedRef?
    var remote: AlarmRemote?

    var id: String { "\(gid)/\(aid)" }
    var date: Date { ts.asDate }
    var isActive: Bool { status == nil || status == 1 }
    var typeName: String { AlarmType.name(type) }
    var deviceName: String { device?.name ?? device?.ip ?? "" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        aid = c.string("aid") ?? UUID().uuidString
        gid = c.string("gid") ?? ""
        type = c.int("type") ?? 0
        status = c.int("status")
        message = c.string("message") ?? ""
        ts = c.double("ts") ?? 0
        direction = c.string("direction")
        device = c.object("device")
        remote = c.object("remote")
    }
}

enum AlarmType {
    static let all: [(Int, String, String)] = [
        (1, "Security Activity", "exclamationmark.shield.fill"),
        (2, "Abnormal Upload", "arrow.up.circle.fill"),
        (3, "Large Bandwidth Usage", "speedometer"),
        (4, "Monthly Data Plan", "chart.pie.fill"),
        (5, "New Device", "plus.circle.fill"),
        (6, "Device Back Online", "wifi"),
        (7, "Device Offline", "wifi.slash"),
        (8, "Video Activity", "play.rectangle.fill"),
        (9, "Gaming Activity", "gamecontroller.fill"),
        (10, "Porn Activity", "eye.slash.fill"),
        (11, "VPN Activity", "lock.shield.fill"),
        (12, "VPN Connection Restored", "checkmark.shield.fill"),
        (13, "VPN Connection Error", "xmark.shield.fill"),
        (14, "Open Port", "door.left.hand.open"),
        (15, "Internet Connectivity Update", "globe"),
        (16, "Large Upload", "arrow.up.to.line"),
    ]
    static func name(_ t: Int) -> String { all.first { $0.0 == t }?.1 ?? "Type \(t)" }
    static func icon(_ t: Int) -> String { all.first { $0.0 == t }?.2 ?? "bell.fill" }
    static func isSecurity(_ t: Int) -> Bool { [1, 2, 10, 13, 14, 16].contains(t) }
}

struct Flow: Decodable, Identifiable, Hashable {
    /// Built from the flow's own fields so it stays the same across reloads
    /// (a random UUID made the table lose its selection and scroll position).
    var id: String = ""
    var ts: Double
    var gid: String?
    var proto: String?
    var direction: String?
    var block: Bool
    var download: Double
    var upload: Double
    var duration: Double?
    var category: String?
    var count: Int?
    var region: String?
    var device: NamedRef?
    var source: NamedRef?
    var destination: NamedRef?

    var date: Date { ts.asDate }
    var tsSort: Double { ts }
    var total: Double { download + upload }
    var deviceName: String { device?.name ?? device?.ip ?? source?.name ?? source?.ip ?? "" }
    var destinationName: String { destination?.name ?? destination?.ip ?? "" }
    var categoryName: String { category ?? "" }
    var regionName: String { region ?? "" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        ts = c.double("ts") ?? 0
        gid = c.string("gid")
        proto = c.string("protocol")
        direction = c.string("direction")
        block = c.bool("block") ?? false
        download = c.double("download") ?? 0
        upload = c.double("upload") ?? 0
        duration = c.double("duration")
        category = c.string("category")
        count = c.int("count")
        region = c.string("region")
        device = c.object("device")
        source = c.object("source")
        destination = c.object("destination")
        id = [String(ts), gid ?? "", device?.id ?? source?.ip ?? "", destination?.ip ?? destination?.name ?? "",
              proto ?? "", direction ?? "", block ? "b" : "a"].joined(separator: "|")
    }

    /// Makes IDs unique when the API returns two flows with identical fields.
    static func withUniqueIDs(_ flows: [Flow]) -> [Flow] {
        var seen: [String: Int] = [:]
        return flows.map { flow in
            var flow = flow
            let n = seen[flow.id, default: 0]
            seen[flow.id] = n + 1
            if n > 0 { flow.id += "#\(n)" }
            return flow
        }
    }
}

struct TrendPoint: Decodable, Identifiable, Hashable {
    var ts: Double
    var value: Double
    var id: Double { ts }
    var date: Date { ts.asDate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        ts = c.double("ts") ?? 0
        value = c.double("value") ?? 0
    }
}

struct Page<T: Decodable>: Decodable {
    /// Number of items in this page (not the total), as observed on the real API.
    var count: Int
    var results: [T]
    var nextCursor: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        results = (try? c.decode([T].self, forKey: AnyCodingKey("results"))) ?? []
        count = c.int("count") ?? results.count
        nextCursor = c.string("next_cursor")
    }
}

// MARK: - Formatting

enum Fmt {
    /// Format text in the app's UI language (English), keeping the user's region settings.
    static let locale: Locale = {
        var comps = Locale.Components(locale: .current)
        comps.languageComponents = Locale.Language.Components(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return Locale(components: comps)
    }()

    // Formatters are expensive to create, so they are built once and reused for every table cell.
    // Only used from the main thread (SwiftUI views).
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        return f
    }()
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = locale
        return f
    }()
    private static let dateTimeStyle = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)

    static func bytes(_ v: Double) -> String {
        byteFormatter.string(fromByteCount: Int64(v))
    }
    static func relative(_ d: Date) -> String {
        relativeFormatter.localizedString(for: d, relativeTo: Date())
    }
    static func dateTime(_ d: Date) -> String {
        d.formatted(dateTimeStyle)
    }
}

// MARK: - Rules

struct RuleTarget: Decodable, Hashable {
    var type: String
    var value: String?
    var dnsOnly: Bool?
    var port: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        type = c.string("type") ?? ""
        value = c.string("value")
        dnsOnly = c.bool("dnsOnly")
        port = c.string("port")
    }

    var description: String {
        let v = value ?? ""
        let base: String
        switch type {
        case "app": base = "App: \(v)"
        case "category": base = "Category: \(v)"
        case "domain", "ip", "net": base = v
        case "internet": base = "Internet"
        case "intranet": base = v.isEmpty ? "Local networks" : "Local network \(v)"
        case "region": base = "Region: \(v)"
        case "remotePort": base = "Remote port \(v)"
        case "targetlist": base = "Target list \(v)"
        default: base = v.isEmpty ? type : "\(type): \(v)"
        }
        if let port, !port.isEmpty { return "\(base):\(port)" }
        return base
    }
}

struct RuleScope: Decodable, Hashable {
    var type: String
    var value: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        type = c.string("type") ?? ""
        value = c.string("value")
    }
}

struct Rule: Decodable, Identifiable, Hashable {
    var id: String
    var name: String?
    var action: String
    var target: RuleTarget?
    var direction: String?
    var gid: String?
    var scope: RuleScope?
    var notes: String
    var status: String
    var ts: Double?
    var updateTs: Double?
    var resumeTs: Double?
    var hitCount: Int?
    var lastHitTs: Double?

    var isActive: Bool { status != "paused" }
    var hitSort: Int { hitCount ?? 0 }
    var targetDescription: String { target?.description ?? "—" }
    var title: String {
        if let name, !name.isEmpty { return name }
        if !notes.isEmpty { return notes }
        return targetDescription
    }
    // Sort helpers for Table columns
    var activeSort: Int { isActive ? 1 : 0 }
    var updatedSort: Double { updateTs ?? ts ?? 0 }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        id = c.string("id") ?? UUID().uuidString
        name = c.string("name")
        action = c.string("action") ?? "block"
        target = c.object("target")
        direction = c.string("direction")
        gid = c.string("gid")
        scope = c.object("scope")
        notes = c.string("notes") ?? ""
        status = c.string("status") ?? "active"
        ts = c.double("ts")
        updateTs = c.double("updateTs")
        resumeTs = c.double("resumeTs")
        if let hit = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("hit")) {
            hitCount = hit.int("count")
            lastHitTs = hit.double("lastHitTs")
        }
    }

    static func actionIcon(_ action: String) -> String {
        switch action {
        case "allow": return "checkmark.circle.fill"
        case "timelimit": return "hourglass"
        default: return "hand.raised.fill"
        }
    }
}
