import Foundation
import CryptoKit

protocol UsageAPI {
    func fetch(account: Account) async throws -> UsageSnapshot
}

enum UsageAPIError: LocalizedError {
    case notLoggedIn
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Not signed in — open Settings → Login"
        case .parse(let s): return "Parse error: \(s)"
        }
    }
}

// MARK: - Claude

/// Calls Claude Code's `/api/oauth/usage` for plan-relative percentages.
/// Response shape (from the CLI binary's statusline doc):
///   { five_hour: { used_percentage, resets_at },
///     seven_day: { used_percentage, resets_at },
///     seven_day_opus: { ... } }
struct AnthropicUsageAPI: UsageAPI {
    func fetch(account: Account) async throws -> UsageSnapshot {
        // Try to load LLimit's own per-account credential first.
        var auth: AuthBundle?
        do {
            auth = try ClaudeAuthSource(accountId: account.id).load()
        } catch {
            FileHandle.standardError.write(Data("[claude] keychain read failed: \(error)\n".utf8))
            auth = nil
        }

        guard auth != nil else {
            throw UsageAPIError.notLoggedIn
        }

        // Anthropic OAuth access tokens expire in ~8 hours. If ours is
        // near the cliff, use the refresh_token to mint a new pair before
        // making any API calls — otherwise the user silently freezes on
        // stale data for 8 hours until they re-sign-in. Skip for session
        // auth (cookie-based, no refresh token).
        if let current = auth,
           !current.isSessionAuth,
           let refreshToken = current.refreshToken,
           let expiresAt = current.expiresAt,
           expiresAt.timeIntervalSinceNow < 120 {
            do {
                let newToken = try await ClaudeOAuthLogin.refresh(refreshToken: refreshToken)
                try ClaudeAuthSource.saveOAuth(
                    accessToken: newToken.accessToken,
                    // Anthropic may rotate the refresh_token; keep the old
                    // one if they don't return a new one.
                    refreshToken: newToken.refreshToken ?? refreshToken,
                    expiresIn: newToken.expiresIn,
                    for: account.id
                )
                auth = try? ClaudeAuthSource(accountId: account.id).load()
            } catch {
                // Refresh failed — token is dead. Surface as notLoggedIn
                // so the UI prompts the user to re-sign-in.
                FileHandle.standardError.write(Data("[claude] refresh failed: \(error)\n".utf8))
                throw UsageAPIError.notLoggedIn
            }
        }

        // Fetch profile (email, plan) and usage via the OAuth token directly,
        // so the Claude CLI doesn't need to be installed or logged in.
        var profileEmail: String? = nil
        var profilePlan: String? = nil
        var profileOrg: String? = nil
        if let auth, !auth.isSessionAuth {
            if let profile = try? await Self.fetchProfile(token: auth.accessToken) {
                profileEmail = profile.account.email
                profilePlan = Self.planLabel(from: profile)
                profileOrg = profile.organization.name
            }
        }

        var windows: [UsageWindow] = []
        var limitsResult: RateLimits? = nil
        if let auth {
            do {
                if auth.isSessionAuth, let orgId = auth.organizationId {
                    limitsResult = try await Self.fetchRateLimitsViaSession(
                        sessionKey: auth.accessToken, organizationId: orgId
                    )
                } else {
                    limitsResult = try await Self.fetchRateLimits(token: auth.accessToken)
                }
            } catch {
                FileHandle.standardError.write(Data("[claude] usage fetch failed: \(error)\n".utf8))
            }
        }

        if let limits = limitsResult {
            if let fh = limits.fiveHour {
                windows.append(UsageWindow(
                    label: "5h",
                    usedPercent: fh.usedPercentage / 100.0,
                    resetsAt: fh.resetsAtDate
                ))
            }
            if let sd = limits.sevenDay {
                windows.append(UsageWindow(
                    label: "7d",
                    usedPercent: sd.usedPercentage / 100.0,
                    resetsAt: sd.resetsAtDate
                ))
            }
            if let op = limits.sevenDayOpus {
                windows.append(UsageWindow(
                    label: "7d opus",
                    usedPercent: op.usedPercentage / 100.0,
                    resetsAt: op.resetsAtDate
                ))
            }
        }

        return UsageSnapshot(
            fetchedAt: Date(),
            windows: windows,
            note: nil,
            email: profileEmail,
            planLabel: profilePlan,
            organization: profileOrg
        )
    }

    fileprivate struct RateLimit: Codable {
        let utilization: Double
        let resetsAt: String?
        var usedPercentage: Double { utilization }
        var resetsAtDate: Date? {
            guard let s = resetsAt else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }
        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    fileprivate struct RateLimits: Codable {
        let fiveHour: RateLimit?
        let sevenDay: RateLimit?
        let sevenDayOpus: RateLimit?
        let sevenDaySonnet: RateLimit?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
        }
    }

    /// Anthropic rate-limits `/api/oauth/usage` aggressively (429 within
     /// 1–2 back-to-back requests on the same token). The CLI only has ONE
     /// keychain entry, so two LLimit accounts pointing at different
     /// configDirs end up sharing the same OAuth token — a `withTaskGroup`
     /// refresh fires both in parallel and the second always 429s.
     /// We coalesce per-token: in-flight requests share a single `Task` and
     /// successful responses are cached briefly so subsequent refreshes
     /// don't re-hit the wire.
    private static func fetchRateLimits(token: String) async throws -> RateLimits {
        try await RateLimitsCache.shared.fetch(token: token) { tok in
            try await Self.doFetchRateLimits(token: tok)
        }
    }

    /// Session-cookie variant — hits claude.ai's web API (same JSON shape as
    /// the OAuth endpoint, just a different host + Cookie auth). Goes through
    /// the same per-key cache so back-to-back account refreshes don't 429.
    private static func fetchRateLimitsViaSession(sessionKey: String,
                                                  organizationId: String) async throws -> RateLimits {
        let key = "session:\(sessionKey)"
        return try await RateLimitsCache.shared.fetch(token: key) { _ in
            try await Self.doFetchRateLimitsViaSession(
                sessionKey: sessionKey, organizationId: organizationId
            )
        }
    }

    fileprivate static func doFetchRateLimitsViaSession(sessionKey: String,
                                                        organizationId: String) async throws -> RateLimits {
        var comps = URLComponents(string: "https://claude.ai/api/organizations")!
        comps.path += "/\(organizationId)/usage"
        guard let url = comps.url else {
            throw UsageAPIError.parse("Invalid organization ID")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        req.setValue("https://claude.ai/", forHTTPHeaderField: "Referer")
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        FileHandle.standardError.write(Data("[claude] claude.ai/api usage HTTP \(status)\n".utf8))
        if status == 401 || status == 403 {
            throw UsageAPIError.notLoggedIn
        }
        if status >= 400 {
            throw UsageAPIError.parse("HTTP \(status)")
        }
        return try JSONDecoder().decode(RateLimits.self, from: data)
    }

    fileprivate static func doFetchRateLimits(token: String) async throws -> RateLimits {
        try await AnthropicRequestGate.shared.run {
            try await Self.sendRateLimitsRequest(token: token)
        }
    }

    private static func sendRateLimitsRequest(token: String) async throws -> RateLimits {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("claude-code/2.1.112 (LLimit)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        FileHandle.standardError.write(Data("[claude] /api/oauth/usage HTTP \(status)\n".utf8))
        if status >= 400 {
            throw UsageAPIError.parse("HTTP \(status)")
        }
        return try JSONDecoder().decode(RateLimits.self, from: data)
    }

    // MARK: - Profile

    struct ProfileResponse: Decodable {
        let account: ProfileAccount
        let organization: ProfileOrganization
    }
    struct ProfileAccount: Decodable {
        let email: String?
        let hasClaude_max: Bool?     // snake_case from API
        let hasClaudePro: Bool?

        enum CodingKeys: String, CodingKey {
            case email
            case hasClaude_max = "has_claude_max"
            case hasClaudePro = "has_claude_pro"
        }
    }
    struct ProfileOrganization: Decodable {
        let name: String?
        let organizationType: String?

        enum CodingKeys: String, CodingKey {
            case name
            case organizationType = "organization_type"
        }
    }

    static func fetchProfile(token: String) async throws -> ProfileResponse {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-code/2.1.112 (LLimit)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if status >= 400 {
            throw UsageAPIError.parse("profile HTTP \(status)")
        }
        return try JSONDecoder().decode(ProfileResponse.self, from: data)
    }

    static func planLabel(from profile: ProfileResponse) -> String? {
        if let orgType = profile.organization.organizationType {
            switch orgType {
            case "claude_max": return "max plan"
            case "claude_pro": return "pro plan"
            case "claude_team": return "team plan"
            case "claude_enterprise": return "enterprise plan"
            case "claude_free": return "free plan"
            default: return "\(orgType) plan"
            }
        }
        if profile.account.hasClaude_max == true { return "max plan" }
        if profile.account.hasClaudePro == true { return "pro plan" }
        return nil
    }

}

/// Anthropic 429s `/api/oauth/usage` when two requests land back-to-back from
/// the same IP — even with different bearer tokens. The refresh coordinator
/// fans out across accounts in parallel, which means a 2-account user almost
/// always loses one window to a rate-limit. Serializing requests through this
/// gate (with a small spacing so the bucket can refill) lets all accounts
/// fetch successfully; the disk cache below covers any that still 429.
private actor AnthropicRequestGate {
    static let shared = AnthropicRequestGate()
    private var lastRequestAt: Date?
    private let minSpacing: TimeInterval = 1.5

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        if let last = lastRequestAt {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minSpacing {
                let wait = minSpacing - elapsed
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        lastRequestAt = Date()
        return try await work()
    }
}

private actor RateLimitsCache {
    static let shared = RateLimitsCache()

    private struct Entry: Codable {
        let value: AnthropicUsageAPI.RateLimits
        let at: Date
    }

    /// Keyed by `tokenHash(token)` so we never write raw bearers to filenames.
    private var cache: [String: Entry] = [:]
    private var inflight: [String: Task<AnthropicUsageAPI.RateLimits, Error>] = [:]
    private let ttl: TimeInterval = 45

    private static var cacheDir: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("LLimit/usage_cache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    private static func tokenHash(_ token: String) -> String {
        let h = SHA256.hash(data: Data(token.utf8))
        return h.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func diskURL(forKey key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).json")
    }

    private func loadFromDisk(key: String) -> Entry? {
        let url = Self.diskURL(forKey: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        return entry
    }

    private func writeToDisk(key: String, entry: Entry) {
        let url = Self.diskURL(forKey: key)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    func fetch(
        token: String,
        perform: @Sendable @escaping (String) async throws -> AnthropicUsageAPI.RateLimits
    ) async throws -> AnthropicUsageAPI.RateLimits {
        let key = Self.tokenHash(token)

        // Hot path: in-memory hit, fresh.
        if let entry = cache[key], Date().timeIntervalSince(entry.at) < ttl {
            return entry.value
        }

        // First touch this process — bring whatever's on disk into memory so
        // a cold start at the moment Anthropic is 429ing still has SOMETHING
        // to show. The disk entry may be stale; we still try a network fetch
        // and only fall back to the disk entry if the fetch fails.
        if cache[key] == nil, let disk = loadFromDisk(key: key) {
            cache[key] = disk
            if Date().timeIntervalSince(disk.at) < ttl {
                return disk.value
            }
        }

        if let existing = inflight[key] {
            return try await existing.value
        }
        let task = Task<AnthropicUsageAPI.RateLimits, Error> {
            try await perform(token)
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        do {
            let value = try await task.value
            let entry = Entry(value: value, at: Date())
            cache[key] = entry
            writeToDisk(key: key, entry: entry)
            return value
        } catch {
            // Anthropic 429s `/api/oauth/usage` hard, especially for
            // accounts at high utilization — exactly when the user most
            // wants to see the numbers. Fall back to the last persisted
            // RateLimits so the popover keeps showing real (if slightly
            // stale) data instead of "no usage windows".
            if let entry = cache[key] {
                let age = Int(Date().timeIntervalSince(entry.at))
                FileHandle.standardError.write(Data(
                    "[claude] usage fetch failed (\(error)); using cached \(age)s-old data\n".utf8
                ))
                return entry.value
            }
            throw error
        }
    }
}

// MARK: - Codex

/// Hits Codex's live rate-limit endpoint that powers the in-CLI `/status`
/// output (`https://chatgpt.com/backend-api/codex/usage`). The previous
/// implementation parsed `rate_limits` events out of session JSONL files,
/// but those only update *during* a Codex turn — the displayed numbers
/// went stale the moment the session ended. Pulling live data matches what
/// `codex /status` shows.
///
/// Cloudflare bot-challenges curl on this endpoint; URLSession (Apple TLS)
/// passes through cleanly with the right `ChatGPT-Account-Id` + originator
/// headers.
struct OpenAIUsageAPI: UsageAPI {
    func fetch(account: Account) async throws -> UsageSnapshot {
        let auth = try Self.readAuth(configDir: account.configDir)
        let usage = try await Self.fetchLiveUsage(
            token: auth.accessToken,
            accountId: auth.accountId
        )

        var windows: [UsageWindow] = []
        if let p = usage.rateLimit?.primaryWindow {
            windows.append(UsageWindow(
                label: Self.windowLabel(seconds: p.limitWindowSeconds, fallback: "5h"),
                usedPercent: p.usedPercent / 100.0,
                resetsAt: p.resetAtDate
            ))
        }
        if let s = usage.rateLimit?.secondaryWindow {
            windows.append(UsageWindow(
                label: Self.windowLabel(seconds: s.limitWindowSeconds, fallback: "7d"),
                usedPercent: s.usedPercent / 100.0,
                resetsAt: s.resetAtDate
            ))
        }
        // Spark / future model-specific limits come back as a sibling array.
        // Only surface those with non-zero usage so the menu doesn't get
        // cluttered with 0%/0% bars for limits the user has never touched.
        for extra in usage.additionalRateLimits ?? [] {
            let label = extra.limitName ?? "extra"
            if let p = extra.rateLimit?.primaryWindow, p.usedPercent > 0 {
                windows.append(UsageWindow(
                    label: "\(label) 5h",
                    usedPercent: p.usedPercent / 100.0,
                    resetsAt: p.resetAtDate
                ))
            }
            if let s = extra.rateLimit?.secondaryWindow, s.usedPercent > 0 {
                windows.append(UsageWindow(
                    label: "\(label) 7d",
                    usedPercent: s.usedPercent / 100.0,
                    resetsAt: s.resetAtDate
                ))
            }
        }

        return UsageSnapshot(
            fetchedAt: Date(),
            windows: windows,
            note: nil,
            email: usage.email ?? auth.email,
            planLabel: Self.prettyPlan(usage.planType ?? auth.plan).map { "\($0) plan" },
            organization: nil
        )
    }

    private struct Auth {
        let accessToken: String
        let accountId: String
        let email: String?
        let plan: String?
    }

    private static func readAuth(configDir: String) throws -> Auth {
        let path = configDir + "/auth.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              let accountId = tokens["account_id"] as? String else {
            throw UsageAPIError.notLoggedIn
        }
        let idToken = tokens["id_token"] as? String
        let claims = idToken.flatMap(decodeJWTPayload)
        let email = claims?["email"] as? String
        let openai = claims?["https://api.openai.com/auth"] as? [String: Any]
        let plan = openai?["chatgpt_plan_type"] as? String
        return Auth(accessToken: access, accountId: accountId, email: email, plan: plan)
    }

    private static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        guard let data = Data(base64Encoded: s),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func windowLabel(seconds: Int?, fallback: String) -> String {
        guard let s = seconds else { return fallback }
        let mins = s / 60
        if mins % (60 * 24) == 0 { return "\(mins / 60 / 24)d" }
        if mins % 60 == 0 { return "\(mins / 60)h" }
        return "\(mins)m"
    }

    private static func prettyPlan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw.capitalized
        }
    }

    fileprivate struct UsageResponse: Decodable {
        let userId: String?
        let email: String?
        let planType: String?
        let rateLimit: RateLimit?
        let additionalRateLimits: [AdditionalLimit]?

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case email
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
        }
    }

    fileprivate struct AdditionalLimit: Decodable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }
    }

    fileprivate struct RateLimit: Decodable {
        let allowed: Bool?
        let limitReached: Bool?
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case allowed
            case limitReached = "limit_reached"
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    fileprivate struct Window: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Int?
        let resetAfterSeconds: Int?
        let resetAt: Double?

        var resetAtDate: Date? {
            if let resetAt { return Date(timeIntervalSince1970: resetAt) }
            if let resetAfterSeconds { return Date().addingTimeInterval(TimeInterval(resetAfterSeconds)) }
            return nil
        }

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }

    private static func fetchLiveUsage(token: String, accountId: String) async throws -> UsageResponse {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // The endpoint sits behind Cloudflare, which 403s clients whose
        // originator/User-Agent doesn't look like the real codex CLI. These
        // values mirror what the Rust binary sends.
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.setValue("codex_cli_rs/0.121.0 (LLimit)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 || status == 403 {
            FileHandle.standardError.write(Data("[codex] /usage HTTP \(status)\n".utf8))
            throw UsageAPIError.notLoggedIn
        }
        if status >= 400 {
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw UsageAPIError.parse("HTTP \(status) \(body)")
        }
        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }
}

// MARK: - Formatting

func formatTokens(_ n: Int) -> String {
    let v = Double(n)
    if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
    if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
    if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
    return "\(n)"
}
