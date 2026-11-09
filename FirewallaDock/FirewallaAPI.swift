import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case invalidURL
    case insecureURL
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set the URL and token in Settings (⌘,)."
        case .invalidURL: return "Invalid API URL."
        case .insecureURL: return "The API URL must start with https:// so the token is never sent unencrypted."
        case .http(401, _): return "Invalid token or insufficient permissions (HTTP 401). Changes require a Full Access token."
        case .http(404, _): return "Endpoint not found (HTTP 404). Check the base URL."
        case .http(let code, let body): return "HTTP error \(code): \(body.prefix(200))"
        case .decoding(let msg): return "Unexpected API response: \(msg)"
        }
    }
}

/// Client for the Firewalla MSP API v2 (https://docs.firewalla.net).
/// Base URL: `https://<yourdomain>.firewalla.net` or `https://firewalla.net/api`.
struct FirewallaAPI {
    let baseURL: String
    let token: String

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || token.isEmpty { throw APIError.notConfigured }
        if !base.lowercased().hasPrefix("http") { base = "https://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard var comps = URLComponents(string: base + path) else { throw APIError.invalidURL }
        // Never send the token unencrypted
        guard comps.scheme?.lowercased() == "https", comps.host?.isEmpty == false else { throw APIError.insecureURL }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await Self.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(try request(path, query: query))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    // MARK: Endpoint

    func boxes() async throws -> [Box] {
        try await get("/v2/boxes")
    }

    func devices(box: String? = nil) async throws -> [Device] {
        try await get("/v2/devices", query: box.map { [URLQueryItem(name: "box", value: $0)] } ?? [])
    }

    /// Fetches alarms, following pagination up to `max` items.
    func alarms(query: String? = "status:active", max: Int = 500) async throws -> [Alarm] {
        try await paged("/v2/alarms", query: query, max: max)
    }

    func flows(query: String? = nil, max: Int = 500) async throws -> [Flow] {
        try await paged("/v2/flows", query: query, max: max)
    }

    func alarmTrend() async throws -> [TrendPoint] { try await get("/v2/trends/alarms") }
    func blockedFlowTrend() async throws -> [TrendPoint] { try await get("/v2/trends/flows") }

    func rules() async throws -> [Rule] {
        let page: Page<Rule> = try await get("/v2/rules")
        return page.results
    }

    // MARK: Write endpoints (require a "Full Access" token)

    /// POST /v2/alarms/:gid/:aid/archive (MSP 2.11.0+). No body.
    func archive(_ alarm: Alarm) async throws {
        _ = try await send(try request("/v2/alarms/\(alarm.gid)/\(alarm.aid)/archive", method: "POST"))
    }

    /// POST /v2/rules/:id/pause or /resume. No body.
    func setRule(_ rule: Rule, active: Bool) async throws {
        let id = rule.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rule.id
        _ = try await send(try request("/v2/rules/\(id)/\(active ? "resume" : "pause")", method: "POST"))
    }

    /// POST /v2/alarms/:gid/:aid/mute (MSP 2.11.0+).
    /// Firewalla archives this alarm and stops creating matching ones (a silence exception).
    func mute(_ alarm: Alarm, target: APIPart, scope: APIPart) async throws {
        let body = try JSONEncoder().encode(MuteBody(target: target, scope: scope))
        _ = try await send(try request("/v2/alarms/\(alarm.gid)/\(alarm.aid)/mute", method: "POST", body: body))
    }

    /// DELETE /v2/rules/:id (MSP 2.11.0+).
    func deleteRule(_ rule: Rule) async throws {
        let id = rule.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rule.id
        _ = try await send(try request("/v2/rules/\(id)", method: "DELETE"))
    }

    /// POST /v2/rules: creates a block rule and returns it.
    func createBlockRule(gid: String, target: APIPart, scope: APIPart?, notes: String) async throws -> Rule {
        let body = try JSONEncoder().encode(
            NewRuleBody(action: "block", direction: "bidirection", gid: gid, notes: notes, target: target, scope: scope)
        )
        let data = try await send(try request("/v2/rules", method: "POST", body: body))
        do {
            return try JSONDecoder().decode(Rule.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    private func paged<T: Decodable>(_ path: String, query: String?, max: Int) async throws -> [T] {
        var all: [T] = []
        var cursor: String?
        repeat {
            var q = [URLQueryItem(name: "limit", value: String(min(500, max - all.count)))]
            if let query, !query.isEmpty { q.append(URLQueryItem(name: "query", value: query)) }
            if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: Page<T> = try await get(path, query: q)
            all += page.results
            cursor = page.nextCursor
            if page.results.isEmpty { break }
        } while cursor != nil && all.count < max
        return all
    }
}

// MARK: - Request bodies

/// A `{type, value}` pair used by mute targets/scopes and rule targets/scopes.
/// `value` is omitted from the JSON when nil (e.g. `{"type": "all"}`).
struct APIPart: Encodable, Hashable {
    var type: String
    var value: String?
}

private struct MuteBody: Encodable {
    var target: APIPart
    var scope: APIPart
}

private struct NewRuleBody: Encodable {
    var action: String
    var direction: String
    var gid: String
    var notes: String
    var target: APIPart
    var scope: APIPart?
}
