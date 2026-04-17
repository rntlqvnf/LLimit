import Foundation

struct AuthBundle {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

protocol AuthSource {
    func load() throws -> AuthBundle
}

struct ClaudeAuthSource: AuthSource {
    let configDir: String

    func load() throws -> AuthBundle {
        let raw = try Keychain.readGenericPassword(service: "Claude Code-credentials")
        guard let data = raw.data(using: .utf8) else { throw KeychainError.unexpectedData }

        struct Outer: Decodable { let claudeAiOauth: Inner }
        struct Inner: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Double?
        }
        let decoded = try JSONDecoder().decode(Outer.self, from: data)
        let exp = decoded.claudeAiOauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000.0) }
        return AuthBundle(
            accessToken: decoded.claudeAiOauth.accessToken,
            refreshToken: decoded.claudeAiOauth.refreshToken,
            expiresAt: exp
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
                expiresAt: nil
            )
        }
        throw NSError(domain: "Codex", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "No access token in auth.json"])
    }
}
