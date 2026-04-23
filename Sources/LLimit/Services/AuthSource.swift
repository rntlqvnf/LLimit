import Foundation

struct AuthBundle {
    var accessToken: String          // OAuth: bearer; Session: sessionKey cookie value
    var refreshToken: String?
    var expiresAt: Date?
    var organizationId: String?      // Set only for session-based auth

    var isSessionAuth: Bool { organizationId != nil }
}

protocol AuthSource {
    func load() throws -> AuthBundle
}

/// Per-account credential storage at
/// `~/Library/Application Support/LLimit/credentials/<account-uuid>.json`.
///
/// Two snapshot shapes are supported, in this order of preference:
///
/// 1) **Session-cookie auth** (new, what the in-app `claude.ai/login`
///    WKWebView produces):
///       { "claudeAiSession": { "sessionKey": "...", "organizationId": "..." } }
///    The `sessionKey` is the same cookie claude.ai's web app uses; combined
///    with an organization UUID it grants `claude.ai/api/...` access. This is
///    the route LLimit prefers for new sign-ins because it works in an
///    embedded WKWebView (Anthropic's OAuth /authorize page rejects WebKit
///    UAs, so the OAuth route was a dead end).
///
/// 2) **OAuth bearer auth** (legacy, kept for backwards compat with the
///    Claude CLI keychain blob and any older snapshots):
///       { "claudeAiOauth": { "accessToken": "...", "refreshToken": "...", ... } }
struct ClaudeAuthSource: AuthSource {
    let accountId: UUID

    static func snapshotURL(for accountId: UUID) -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("LLimit/credentials", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("\(accountId.uuidString).json")
    }

    static func hasSnapshot(for accountId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: snapshotURL(for: accountId).path)
    }

    /// Read the global Claude CLI keychain entry and stash it as a per-account
    /// snapshot in legacy OAuth-blob shape. Used by the older "Sync from CLI"
    /// path; the new in-app sign-in writes session shape via `saveSession(...)`.
    static func snapshotKeychain(for accountId: UUID) throws {
        let raw = try Keychain.readGenericPassword(service: "Claude Code-credentials")
        let url = snapshotURL(for: accountId)
        try raw.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    /// Persist an OAuth bearer captured from our PKCE flow (the same flow
    /// `claude login` uses, but redirected at our localhost listener so the
    /// token lands in this per-account file instead of the global keychain).
    static func saveOAuth(accessToken: String,
                          refreshToken: String?,
                          expiresIn: Int?,
                          for accountId: UUID) throws {
        var inner: [String: Any] = ["accessToken": accessToken]
        if let r = refreshToken { inner["refreshToken"] = r }
        if let s = expiresIn {
            // Store in ms-since-epoch to match the legacy CLI keychain shape
            // already understood by `load()`.
            let ms = (Date().timeIntervalSince1970 + Double(s)) * 1000.0
            inner["expiresAt"] = ms
        }
        let blob: [String: Any] = ["claudeAiOauth": inner]
        let data = try JSONSerialization.data(withJSONObject: blob, options: [])
        let url = snapshotURL(for: accountId)
        try data.write(to: url, options: .atomic)
        // Paranoia: atomic write doesn't guarantee the file is readable
        // afterwards (read-only parent dir, disk full, etc.). Surface a
        // clear error instead of silently returning success and having
        // load() throw later.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "ClaudeAuth", code: -20,
                userInfo: [NSLocalizedDescriptionKey: "Failed to persist credential snapshot."]
            )
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    static func deleteSnapshot(for accountId: UUID) {
        try? FileManager.default.removeItem(at: snapshotURL(for: accountId))
    }

    /// Loads the per-account credential snapshot. Throws `notLoggedIn` if
    /// no snapshot exists.
    ///
    /// We intentionally do NOT fall back to the Claude CLI's global
    /// `"Claude Code-credentials"` keychain entry anymore. That fallback
    /// looked helpful when only one account existed, but with N accounts
    /// every account without its own snapshot saw the same CLI token —
    /// which meant "Account B" would silently report "Account A"'s usage,
    /// or falsely appear signed-in. Existing single-account users are
    /// carried forward by `AccountStore.migrateKeychainIfNeeded()` which
    /// snapshots the keychain into the first Claude account on upgrade.
    func load() throws -> AuthBundle {
        let snapshot = Self.snapshotURL(for: accountId)
        guard let rawData = try? String(contentsOf: snapshot, encoding: .utf8),
              !rawData.isEmpty,
              let data = rawData.data(using: .utf8) else {
            throw UsageAPIError.notLoggedIn
        }

        // Prefer the new session-cookie shape if present.
        struct SessionOuter: Decodable { let claudeAiSession: SessionInner }
        struct SessionInner: Decodable {
            let sessionKey: String
            let organizationId: String
        }
        if let s = try? JSONDecoder().decode(SessionOuter.self, from: data) {
            return AuthBundle(
                accessToken: s.claudeAiSession.sessionKey,
                refreshToken: nil,
                expiresAt: nil,
                organizationId: s.claudeAiSession.organizationId
            )
        }

        // Legacy OAuth shape — still the default for LLimit's PKCE flow.
        struct OAuthOuter: Decodable { let claudeAiOauth: OAuthInner }
        struct OAuthInner: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Double?
        }
        let decoded = try JSONDecoder().decode(OAuthOuter.self, from: data)
        let exp = decoded.claudeAiOauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000.0) }
        return AuthBundle(
            accessToken: decoded.claudeAiOauth.accessToken,
            refreshToken: decoded.claudeAiOauth.refreshToken,
            expiresAt: exp,
            organizationId: nil
        )
    }
}

struct CodexAuthSource: AuthSource {
    let configDir: String

    func load() throws -> AuthBundle {
        let url = URL(fileURLWithPath: configDir).appendingPathComponent("auth.json")
        let data = try Data(contentsOf: url)

        struct Auth: Decodable {
            let OPENAI_API_KEY: String?
            let tokens: Tokens?

            struct Tokens: Decodable {
                let access_token: String?
                let refresh_token: String?
                let id_token: String?
            }
        }
        let decoded = try JSONDecoder().decode(Auth.self, from: data)
        if let token = decoded.tokens?.access_token ?? decoded.OPENAI_API_KEY {
            return AuthBundle(
                accessToken: token,
                refreshToken: decoded.tokens?.refresh_token,
                expiresAt: nil,
                organizationId: nil
            )
        }
        throw NSError(domain: "Codex", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "No access token in auth.json"])
    }
}
