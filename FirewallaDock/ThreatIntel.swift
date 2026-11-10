import Foundation
import Network

// MARK: - Indicators

/// A remote IP or domain taken from an alarm. Only public addresses and domains are ever sent
/// to a reputation service; local, private and reserved ones are filtered out.
struct Indicator: Hashable, Codable, Identifiable {
    enum Kind: String, Codable { case ip, domain }
    var kind: Kind
    var value: String
    var id: String { "\(kind.rawValue):\(value)" }

    /// Public indicators of an alarm: its remote domain and its remote IP, when present.
    static func from(_ alarm: Alarm) -> [Indicator] {
        var out: [Indicator] = []
        if let domain = alarm.remote?.domain?.lowercased(), isPublicDomain(domain) {
            out.append(Indicator(kind: .domain, value: domain))
        }
        if let ip = alarm.remote?.ip, isPublicIP(ip) {
            out.append(Indicator(kind: .ip, value: ip))
        }
        return out
    }

    static func isPublicIP(_ s: String) -> Bool {
        if let v4 = IPv4Address(s) {
            let b = [UInt8](v4.rawValue)
            switch (b[0], b[1]) {
            case (0, _), (10, _), (127, _): return false                 // this network, private, loopback
            case (100, 64...127): return false                           // carrier-grade NAT
            case (169, 254): return false                                // link-local
            case (172, 16...31), (192, 168): return false                // private
            case (192, 0) where b[2] == 2, (198, 51) where b[2] == 100,
                 (203, 0) where b[2] == 113: return false                // documentation
            case (198, 18...19): return false                            // benchmarking
            case (224...255, _): return false                            // multicast, reserved, broadcast
            default: return true
            }
        }
        if let v6 = IPv6Address(s) {
            let b = [UInt8](v6.rawValue)
            if b.allSatisfy({ $0 == 0 }) { return false }                // ::
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return false } // ::1
            if b[0] & 0xFE == 0xFC { return false }                      // fc00::/7 unique local
            if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return false }      // fe80::/10 link-local
            if b[0] == 0xFF { return false }                             // multicast
            if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8 { return false } // documentation
            if v6.asIPv4 != nil { return v6.asIPv4.map { isPublicIP("\($0)") } ?? false }
            return true
        }
        return false
    }

    static func isPublicDomain(_ d: String) -> Bool {
        guard d.contains("."), !d.hasSuffix("."), IPv4Address(d) == nil, IPv6Address(d) == nil else { return false }
        let local = [".local", ".lan", ".home", ".home.arpa", ".internal", ".localdomain", ".arpa", ".localhost", ".test", ".invalid"]
        return !local.contains { d.hasSuffix($0) }
    }
}

// MARK: - Services

enum ThreatService: String, Codable, CaseIterable, Identifiable {
    case virusTotal, abuseIPDB, shodan, abuseCH

    var id: String { rawValue }

    var name: String {
        switch self {
        case .virusTotal: return "VirusTotal"
        case .abuseIPDB: return "AbuseIPDB"
        case .shodan: return "Shodan InternetDB"
        case .abuseCH: return "abuse.ch"
        }
    }

    var needsKey: Bool { self != .shodan }
    var keychainAccount: String { "threatintel-\(rawValue)" }

    func supports(_ kind: Indicator.Kind) -> Bool {
        switch self {
        case .virusTotal, .abuseCH: return true
        case .abuseIPDB, .shodan: return kind == .ip
        }
    }

    /// Seconds between two requests (VirusTotal's free API allows 4 per minute).
    var minInterval: TimeInterval {
        switch self {
        case .virusTotal: return 15
        case .abuseIPDB: return 2
        case .shodan, .abuseCH: return 1
        }
    }

    /// Daily request cap of the free plan (nil: none documented, fair use).
    var dailyLimit: Int? {
        switch self {
        case .virusTotal: return 500
        case .abuseIPDB: return 1000
        case .shodan, .abuseCH: return nil
        }
    }

    /// Requests per lookup (abuse.ch queries ThreatFox and URLhaus).
    var requestsPerLookup: Int { self == .abuseCH ? 2 : 1 }

    var info: String {
        switch self {
        case .virusTotal:
            return "IPs and domains, verdicts from ~90 security vendors. Free key: 4 lookups/min, 500/day, non-commercial use only. Looked-up IPs and domains are added to VirusTotal's dataset."
        case .abuseIPDB:
            return "IPs only: abuse reports from the community and a confidence score. Free key: 1,000 checks/day."
        case .shodan:
            return "IPs only: open ports, known vulnerabilities and tags. No key needed; free for non-commercial use."
        case .abuseCH:
            return "IPs and domains in ThreatFox (malware, botnet C2) and URLhaus (malware sites). Free Auth-Key; fair use, non-commercial."
        }
    }

    var keyURL: URL? {
        switch self {
        case .virusTotal: return URL(string: "https://www.virustotal.com/gui/my-apikey")
        case .abuseIPDB: return URL(string: "https://www.abuseipdb.com/account/api")
        case .abuseCH: return URL(string: "https://auth.abuse.ch/")
        case .shodan: return nil
        }
    }
}

// MARK: - Results

enum ThreatLevel: Int, Codable, Comparable {
    case unknown = 0, clean, suspicious, malicious
    static func < (a: ThreatLevel, b: ThreatLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .unknown: return "No data"
        case .clean: return "Clean"
        case .suspicious: return "Suspicious"
        case .malicious: return "Malicious"
        }
    }
    var icon: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .clean: return "checkmark.shield.fill"
        case .suspicious: return "exclamationmark.triangle.fill"
        case .malicious: return "xmark.shield.fill"
        }
    }
}

struct ServiceResult: Codable, Identifiable, Hashable {
    var service: ThreatService
    var level: ThreatLevel
    var summary: String
    var details: [String] = []
    var link: URL?
    /// Set when the lookup failed; such results are not trusted for the verdict.
    var error: String?
    var id: String { service.rawValue }
}

struct ReputationReport: Codable, Hashable {
    var indicator: Indicator
    var checkedAt: Date
    var results: [ServiceResult]

    /// Worst verdict among the services that answered.
    var level: ThreatLevel { results.filter { $0.error == nil }.map(\.level).max() ?? .unknown }
    var hasErrors: Bool { results.contains { $0.error != nil } }
}

enum ThreatIntelError: LocalizedError {
    case rateLimited(retryAfter: TimeInterval?)
    case badKey
    case http(Int)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .rateLimited: return "Rate limit reached; will retry later"
        case .badKey: return "API key missing or not accepted"
        case .http(let code): return "HTTP error \(code)"
        case .unexpected(let s): return "Unexpected response: \(s)"
        }
    }
}

// MARK: - Clients

/// Stateless lookups. Rate limits and caching are handled by `ThreatIntel`.
struct ThreatIntelClient {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral   // no cookies or cache
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    func lookup(_ service: ThreatService, _ ind: Indicator, key: String) async throws -> ServiceResult {
        switch service {
        case .virusTotal: return try await virusTotal(ind, key: key)
        case .abuseIPDB: return try await abuseIPDB(ind, key: key)
        case .shodan: return try await shodan(ind)
        case .abuseCH: return try await abuseCH(ind, key: key)
        }
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ThreatIntelError.unexpected("no HTTP response") }
        switch http.statusCode {
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ThreatIntelError.rateLimited(retryAfter: retry)
        case 401, 403: throw ThreatIntelError.badKey
        default: return (data, http)
        }
    }

    private func path(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    // VirusTotal API v3: GET /api/v3/ip_addresses/{ip} or /api/v3/domains/{domain}
    private func virusTotal(_ ind: Indicator, key: String) async throws -> ServiceResult {
        let kind = ind.kind == .ip ? "ip_addresses" : "domains"
        var req = URLRequest(url: URL(string: "https://www.virustotal.com/api/v3/\(kind)/\(path(ind.value))")!)
        req.setValue(key, forHTTPHeaderField: "x-apikey")
        let link = URL(string: "https://www.virustotal.com/gui/\(ind.kind == .ip ? "ip-address" : "domain")/\(path(ind.value))")
        let (data, http) = try await send(req)
        if http.statusCode == 404 {
            return ServiceResult(service: .virusTotal, level: .unknown, summary: "Not in VirusTotal", link: link)
        }
        guard http.statusCode == 200 else { throw ThreatIntelError.http(http.statusCode) }

        struct Stats: Decodable { var harmless, malicious, suspicious, undetected, timeout: Int? }
        struct Attrs: Decodable {
            var last_analysis_stats: Stats?
            var reputation: Int?
            var country: String?
            var as_owner: String?
            var last_analysis_date: Double?
        }
        struct Body: Decodable { struct D: Decodable { var attributes: Attrs }; var data: D }
        let a = try JSONDecoder().decode(Body.self, from: data).data.attributes
        let s = a.last_analysis_stats
        let mal = s?.malicious ?? 0, sus = s?.suspicious ?? 0
        let total = [s?.harmless, s?.malicious, s?.suspicious, s?.undetected].compactMap { $0 }.reduce(0, +)
        let level: ThreatLevel = mal >= 3 ? .malicious : (mal >= 1 || sus >= 2 ? .suspicious : (total > 0 ? .clean : .unknown))

        var details: [String] = []
        if sus > 0 { details.append("\(sus) vendor(s) flag it as suspicious") }
        if let r = a.reputation { details.append("Community score: \(r)") }
        let owner = [a.as_owner, a.country].compactMap { $0 }.joined(separator: " · ")
        if !owner.isEmpty { details.append(owner) }
        if let d = a.last_analysis_date { details.append("Last analysis \(Fmt.relative(d.asDate))") }
        return ServiceResult(service: .virusTotal, level: level,
                             summary: total > 0 ? "\(mal) of \(total) vendors flag it as malicious" : "No analysis yet",
                             details: details, link: link)
    }

    // AbuseIPDB API v2: GET /api/v2/check?ipAddress=&maxAgeInDays=90
    private func abuseIPDB(_ ind: Indicator, key: String) async throws -> ServiceResult {
        var comps = URLComponents(string: "https://api.abuseipdb.com/api/v2/check")!
        comps.queryItems = [URLQueryItem(name: "ipAddress", value: ind.value), URLQueryItem(name: "maxAgeInDays", value: "90")]
        var req = URLRequest(url: comps.url!)
        req.setValue(key, forHTTPHeaderField: "Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await send(req)
        guard http.statusCode == 200 else { throw ThreatIntelError.http(http.statusCode) }

        struct D: Decodable {
            var abuseConfidenceScore: Int?
            var totalReports: Int?
            var numDistinctUsers: Int?
            var countryCode: String?
            var isp: String?
            var usageType: String?
            var isWhitelisted: Bool?
            var isTor: Bool?
            var lastReportedAt: String?
        }
        struct Body: Decodable { var data: D }
        let d = try JSONDecoder().decode(Body.self, from: data).data
        let score = d.abuseConfidenceScore ?? 0
        let reports = d.totalReports ?? 0
        let level: ThreatLevel = d.isWhitelisted == true ? .clean : (score >= 75 ? .malicious : (score >= 25 ? .suspicious : .clean))

        var details: [String] = []
        if reports > 0 { details.append("\(reports) report(s) from \(d.numDistinctUsers ?? 0) user(s) in the last 90 days") }
        if let last = d.lastReportedAt, let date = ISO8601DateFormatter().date(from: last) {
            details.append("Last reported \(Fmt.relative(date))")
        }
        if d.isTor == true { details.append("Tor exit node") }
        if d.isWhitelisted == true { details.append("On AbuseIPDB's allow list") }
        let owner = [d.isp, d.usageType, d.countryCode].compactMap { $0 }.joined(separator: " · ")
        if !owner.isEmpty { details.append(owner) }
        return ServiceResult(service: .abuseIPDB, level: level, summary: "Abuse confidence \(score)%",
                             details: details, link: URL(string: "https://www.abuseipdb.com/check/\(path(ind.value))"))
    }

    // Shodan InternetDB: GET /{ip}, no key
    private func shodan(_ ind: Indicator) async throws -> ServiceResult {
        let req = URLRequest(url: URL(string: "https://internetdb.shodan.io/\(path(ind.value))")!)
        let link = URL(string: "https://www.shodan.io/host/\(path(ind.value))")
        let (data, http) = try await send(req)
        if http.statusCode == 404 {
            return ServiceResult(service: .shodan, level: .unknown, summary: "No Shodan data for this IP", link: link)
        }
        guard http.statusCode == 200 else { throw ThreatIntelError.http(http.statusCode) }

        struct Body: Decodable { var ports: [Int]?; var tags: [String]?; var vulns: [String]?; var hostnames: [String]? }
        let b = try JSONDecoder().decode(Body.self, from: data)
        let tags = b.tags ?? []
        let bad = Set(["c2", "malware", "compromised", "botnet"])
        let level: ThreatLevel = tags.contains { bad.contains($0.lowercased()) } ? .suspicious : .unknown

        var details: [String] = []
        if let p = b.ports, !p.isEmpty { details.append("Open ports: \(p.prefix(12).map(String.init).joined(separator: ", "))") }
        if let v = b.vulns, !v.isEmpty { details.append("\(v.count) known vulnerabilit\(v.count == 1 ? "y" : "ies"): \(v.prefix(5).joined(separator: ", "))") }
        if !tags.isEmpty { details.append("Tags: \(tags.joined(separator: ", "))") }
        if let h = b.hostnames, !h.isEmpty { details.append("Hostnames: \(h.prefix(3).joined(separator: ", "))") }
        let summary = level == .suspicious ? "Tagged \(tags.joined(separator: ", "))" : "No threat tags"
        return ServiceResult(service: .shodan, level: level, summary: summary, details: details, link: link)
    }

    // abuse.ch: ThreatFox search_ioc + URLhaus host lookup, both with an Auth-Key header
    private func abuseCH(_ ind: Indicator, key: String) async throws -> ServiceResult {
        var details: [String] = []
        var level = ThreatLevel.clean
        var link = URL(string: "https://threatfox.abuse.ch/browse.php?search=ioc%3A\(ind.value)")

        // ThreatFox: IP IOCs are usually stored as "ip:port" and domains may be URLs,
        // so search without exact_match and keep only the entries for this indicator.
        var tf = URLRequest(url: URL(string: "https://threatfox-api.abuse.ch/api/v1/")!)
        tf.httpMethod = "POST"
        tf.setValue(key, forHTTPHeaderField: "Auth-Key")
        tf.setValue("application/json", forHTTPHeaderField: "Content-Type")
        tf.httpBody = try JSONSerialization.data(withJSONObject: ["query": "search_ioc", "search_term": ind.value, "exact_match": false])
        let (tfData, tfHTTP) = try await send(tf)
        guard tfHTTP.statusCode == 200 else { throw ThreatIntelError.http(tfHTTP.statusCode) }
        struct TFEntry: Decodable { var ioc: String?; var threat_type_desc: String?; var malware_printable: String?; var confidence_level: Int?; var last_seen: String?; var first_seen: String? }
        struct TFBody: Decodable { var query_status: String?; var data: [TFEntry]? }
        // On no result `data` can be a string, so decode it leniently
        let tfBody = (try? JSONDecoder().decode(TFBody.self, from: tfData)) ?? TFBody(query_status: nil, data: nil)
        if let status = tfBody.query_status, !["ok", "no_result", "no_results"].contains(status) {
            if status.contains("auth") || status.contains("key") { throw ThreatIntelError.badKey }
            throw ThreatIntelError.unexpected("ThreatFox: \(status)")
        }
        let hits = (tfBody.data ?? []).filter { matches(ioc: $0.ioc ?? "", ind) }
        if let top = hits.max(by: { ($0.confidence_level ?? 0) < ($1.confidence_level ?? 0) }) {
            level = .malicious
            let what = [top.malware_printable, top.threat_type_desc].compactMap { $0 }.joined(separator: " – ")
            details.append("ThreatFox: \(what) (confidence \(top.confidence_level ?? 0)%)")
        }

        // URLhaus: POST /v1/host/ with form field host
        var uh = URLRequest(url: URL(string: "https://urlhaus-api.abuse.ch/v1/host/")!)
        uh.httpMethod = "POST"
        uh.setValue(key, forHTTPHeaderField: "Auth-Key")
        uh.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        uh.httpBody = Data("host=\(ind.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: ".-:"))) ?? ind.value)".utf8)
        let (uhData, uhHTTP) = try await send(uh)
        guard uhHTTP.statusCode == 200 else { throw ThreatIntelError.http(uhHTTP.statusCode) }
        struct UHURL: Decodable { var url_status: String? }
        struct UHBody: Decodable { var query_status: String?; var url_count: String?; var urls: [UHURL]?; var blacklists: [String: String]? }
        let uhBody = try JSONDecoder().decode(UHBody.self, from: uhData)
        switch uhBody.query_status {
        case "ok":
            let online = (uhBody.urls ?? []).filter { $0.url_status == "online" }.count
            let count = uhBody.url_count ?? "\(uhBody.urls?.count ?? 0)"
            details.append("URLhaus: \(count) malware URL(s), \(online) still online")
            level = max(level, online > 0 ? .malicious : .suspicious)
            link = URL(string: "https://urlhaus.abuse.ch/host/\(ind.value)/")
            for (list, value) in uhBody.blacklists ?? [:] where value != "not listed" {
                details.append("\(list == "spamhaus_dbl" ? "Spamhaus DBL" : list.uppercased()): \(value)")
            }
        case "no_results", "invalid_host", nil:
            break
        case let status?:
            if status.contains("auth") || status.contains("key") { throw ThreatIntelError.badKey }
            throw ThreatIntelError.unexpected("URLhaus: \(status)")
        }

        let summary: String
        switch level {
        case .malicious: summary = "Listed as malicious"
        case .suspicious: summary = "Listed in the past"
        default: summary = "Not listed in ThreatFox or URLhaus"
        }
        return ServiceResult(service: .abuseCH, level: level, summary: summary, details: details, link: link)
    }

    /// Whether a ThreatFox IOC ("1.2.3.4:443", "evil.com", "http://evil.com/x") is this indicator.
    private func matches(ioc: String, _ ind: Indicator) -> Bool {
        let ioc = ioc.lowercased()
        let host: String
        if ioc.contains("://") {
            host = URL(string: ioc)?.host?.lowercased() ?? ""
        } else if ind.kind == .ip && ind.value.contains(":") {
            // IPv6: "[addr]:port" or plain address
            host = ioc.hasPrefix("[") ? String(ioc.dropFirst().prefix { $0 != "]" }) : ioc
        } else {
            host = String(ioc.split(separator: ":").first ?? "")
        }
        return host == ind.value.lowercased()
    }
}
