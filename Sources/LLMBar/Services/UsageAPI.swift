import Foundation

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
        let raw = await CLILoginRunner.runCapture(
            "claude", ["auth", "status"],
            env: ["CLAUDE_CONFIG_DIR": account.configDir]
        )
        struct Status: Decodable {
            let loggedIn: Bool
            let email: String?
            let subscriptionType: String?
        }
        guard let data = raw.data(using: .utf8),
              let status = try? JSONDecoder().decode(Status.self, from: data) else {
            throw UsageAPIError.parse(raw.prefix(80).description)
        }
        guard status.loggedIn else { throw UsageAPIError.notLoggedIn }

        var bits: [String] = []
        if let e = status.email { bits.append(e) }
        if let s = status.subscriptionType { bits.append("\(s) plan") }

        var windows: [UsageWindow] = []

        let auth: AuthBundle?
        do {
            auth = try ClaudeAuthSource(configDir: account.configDir).load()
        } catch {
            FileHandle.standardError.write(Data("[claude] keychain read failed: \(error)\n".utf8))
            auth = nil
        }
        var limitsResult: RateLimits? = nil
        if let auth {
            do {
                limitsResult = try await Self.fetchRateLimits(token: auth.accessToken)
            } catch {
                FileHandle.standardError.write(Data("[claude] /api/oauth/usage failed: \(error)\n".utf8))
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
            if let so = limits.sevenDaySonnet {
                windows.append(UsageWindow(
                    label: "7d sonnet",
                    usedPercent: so.usedPercentage / 100.0,
                    resetsAt: so.resetsAtDate
                ))
            }
        }

        return UsageSnapshot(
            fetchedAt: Date(),
            windows: windows,
            note: bits.joined(separator: " · ")
        )
    }

    private struct RateLimit: Decodable {
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

    private struct RateLimits: Decodable {
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

    private static func fetchRateLimits(token: String) async throws -> RateLimits {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("claude-code/2.1.112 (LLMBar)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? "<binary>"
        FileHandle.standardError.write(Data("[claude] /api/oauth/usage HTTP \(status) body=\(body.prefix(500))\n".utf8))
        if status >= 400 {
            throw UsageAPIError.parse("HTTP \(status)")
        }
        return try JSONDecoder().decode(RateLimits.self, from: data)
    }

}

// MARK: - Codex

/// Codex writes a `token_count` event into every rollout JSONL with a
/// `rate_limits` block (primary = 5h, secondary = weekly). We grab the most
/// recent such event across all session files.
struct OpenAIUsageAPI: UsageAPI {
    func fetch(account: Account) async throws -> UsageSnapshot {
        let raw = await CLILoginRunner.runCapture(
            "codex", ["login", "status"],
            env: ["CODEX_HOME": account.configDir]
        )
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        FileHandle.standardError.write(Data("[codex] status='\(line)'\n".utf8))
        if line.isEmpty || !line.lowercased().contains("logged in") {
            throw UsageAPIError.notLoggedIn
        }

        let snap = await Self.latestRateLimits(sessionsRoot: account.configDir + "/sessions")
        FileHandle.standardError.write(Data("[codex] snap=\(String(describing: snap))\n".utf8))

        var windows: [UsageWindow] = []
        if let p = snap?.primary {
            windows.append(UsageWindow(
                label: Self.windowLabel(minutes: p.windowMinutes, fallback: "5h"),
                usedPercent: p.usedPercent / 100.0,
                resetsAt: p.resetsAt
            ))
        }
        if let s = snap?.secondary {
            windows.append(UsageWindow(
                label: Self.windowLabel(minutes: s.windowMinutes, fallback: "7d"),
                usedPercent: s.usedPercent / 100.0,
                resetsAt: s.resetsAt
            ))
        }

        var noteParts = [line]
        if let total = snap?.totalTokens {
            noteParts.append("\(formatTokens(total)) tokens this session")
        }

        return UsageSnapshot(
            fetchedAt: Date(),
            windows: windows,
            note: noteParts.joined(separator: " · ")
        )
    }

    private static func windowLabel(minutes: Int?, fallback: String) -> String {
        guard let m = minutes else { return fallback }
        if m % (60 * 24) == 0 { return "\(m / 60 / 24)d" }
        if m % 60 == 0 { return "\(m / 60)h" }
        return "\(m)m"
    }

    private struct Limit { let usedPercent: Double; let windowMinutes: Int?; let resetsAt: Date? }
    private struct Snap { let primary: Limit?; let secondary: Limit?; let totalTokens: Int? }

    private static func latestRateLimits(sessionsRoot: String) async -> Snap? {
        await Task.detached(priority: .utility) { () -> Snap? in
            let fm = FileManager.default
            guard let subpaths = fm.subpaths(atPath: sessionsRoot) else { return nil }
            var newest: (Date, String)? = nil
            for sub in subpaths where sub.hasSuffix(".jsonl") {
                let path = sessionsRoot + "/" + sub
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                if newest == nil || mtime > newest!.0 {
                    newest = (mtime, path)
                }
            }
            guard let (_, path) = newest,
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                return nil
            }
            var lastSnap: Snap? = nil
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (any["type"] as? String) == "event_msg",
                      let payload = any["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count" else { continue }
                let limits = payload["rate_limits"] as? [String: Any]
                let primary = parseLimit(limits?["primary"] as? [String: Any])
                let secondary = parseLimit(limits?["secondary"] as? [String: Any])
                let info = payload["info"] as? [String: Any]
                let total = (info?["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int
                lastSnap = Snap(primary: primary, secondary: secondary, totalTokens: total)
            }
            return lastSnap
        }.value
    }

    private static func parseLimit(_ dict: [String: Any]?) -> Limit? {
        guard let d = dict, let used = d["used_percent"] as? Double else { return nil }
        let mins = d["window_minutes"] as? Int
        let resets: Date?
        if let r = d["resets_at"] as? Double {
            resets = Date(timeIntervalSince1970: r)
        } else if let r = d["resets_at"] as? Int {
            resets = Date(timeIntervalSince1970: TimeInterval(r))
        } else {
            resets = nil
        }
        return Limit(usedPercent: used, windowMinutes: mins, resetsAt: resets)
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
