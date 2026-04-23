import Foundation
import Network
import CryptoKit
import AppKit

/// Drives the same PKCE OAuth flow that `claude login` uses, but captures the
/// token into LLimit's per-account JSON snapshot instead of the global Claude
/// CLI keychain entry. That's the whole point: the keychain entry is a single
/// global slot — multi-account is impossible if we let the CLI write there.
///
/// Flow:
/// 1. Spin up an `NWListener` on an ephemeral localhost port.
/// 2. Build an authorize URL with PKCE + our `http://127.0.0.1:<port>/callback`
///    redirect, then `NSWorkspace.shared.open` it in the user's REAL browser
///    (avoids claude.ai's WKWebView bot wall, and forces a real login screen
///    even if the user is already signed into claude.ai).
/// 3. Browser redirects back to our localhost listener with `?code=...`.
/// 4. POST that code + verifier to the token endpoint, get back a bearer.
/// 5. Caller persists the bearer via `ClaudeAuthSource.saveOAuth(...)`.
///
/// OAuth client params reverse-engineered from
/// `https://claude.ai/oauth/claude-code-client-metadata`:
///   - public client (no secret), token_endpoint_auth_method = "none"
///   - redirect_uris: http://127.0.0.1/callback, http://localhost/callback
///   - grant_types: authorization_code, refresh_token
enum ClaudeOAuthLogin {
    /// Claude Code's public OAuth client_id, lifted from the CLI binary
    /// (`/Users/<u>/.local/share/claude/versions/<v>` → strings → CLIENT_ID).
    /// The metadata document URL `claude.ai/oauth/claude-code-client-metadata`
    /// describes the client but is NOT itself the client_id — the authorize
    /// endpoint expects a UUID.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.com/cai/oauth/authorize"
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    static let scopes = "user:inference user:profile org:create_api_key"

    /// The CLI uses a hardcoded port. The OAuth client metadata registers
    /// `http://localhost/callback` and `http://127.0.0.1/callback` with no
    /// port, which by RFC 8252 §7.3 means any localhost port is accepted —
    /// but Anthropic's actual server validation is stricter, and matching
    /// the CLI's port + host removes one variable. The CLI also uses the
    /// hostname `localhost` (not `127.0.0.1`) and the token endpoint requires
    /// the `redirect_uri` in the body to match the one in the authorize URL
    /// byte-for-byte.
    static let redirectPort: UInt16 = 54545
    static let redirectHost = "localhost"
    static var redirectURI: String { "http://\(redirectHost):\(redirectPort)/callback" }

    struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?
        let tokenType: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
            case scope
        }
    }

    /// One end-to-end run. Returns the token from the exchange, or throws.
    ///
    /// Defensive: a prior flow that crashed or was force-quit can leave a
    /// listener bound on `redirectPort`. `PortUtil.freePort` clears it so we
    /// don't hit EADDRINUSE when binding below.
    ///
    /// Pass a `session` to enable external cancellation (Cancel button in
    /// LoginSheet). The session holds a weak reference to the callback
    /// server and can abort the `waitForCallback` continuation.
    static func run(session: ClaudeOAuthSession? = nil) async throws -> TokenResponse {
        PortUtil.freePort(Int(redirectPort))
        let server = try OAuthCallbackServer(port: redirectPort)
        await session?.attach(server)
        do {
            let result = try await runInner(server: server)
            await server.stop()
            await session?.detach()
            return result
        } catch {
            await server.stop()
            await session?.detach()
            throw error
        }
    }

    private static func runInner(server: OAuthCallbackServer) async throws -> TokenResponse {
        try await server.start()

        let verifier = makeCodeVerifier()
        let challenge = makeCodeChallenge(verifier: verifier)
        let state = UUID().uuidString

        var comps = URLComponents(string: authorizeURL)!
        // Order matches the CLI's URL builder so the resulting query string
        // is byte-identical (some auth servers hash the URL for fingerprinting).
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = comps.url else {
            throw NSError(domain: "ClaudeOAuth", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Bad authorize URL"])
        }

        await MainActor.run { NSWorkspace.shared.open(authURL) }
        FileHandle.standardError.write(Data("[oauth] opened browser for authorization\n".utf8))

        let callbackURL = try await server.waitForCallback()
        FileHandle.standardError.write(Data("[oauth] received callback\n".utf8))

        guard let cbComps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let items = cbComps.queryItems else {
            throw NSError(domain: "ClaudeOAuth", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Callback missing query"])
        }
        if let err = items.first(where: { $0.name == "error" })?.value {
            let desc = items.first(where: { $0.name == "error_description" })?.value ?? err
            throw NSError(domain: "ClaudeOAuth", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Authorize denied: \(desc)"])
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw NSError(domain: "ClaudeOAuth", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Callback missing code"])
        }
        let cbState = items.first(where: { $0.name == "state" })?.value
        if let cbState, cbState != state {
            throw NSError(domain: "ClaudeOAuth", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "OAuth state mismatch"])
        }
        // Anthropic's token endpoint REQUIRES `state` in the body — verified
        // by reading `claude-code@1.0.0`'s cli.js token-exchange function:
        //   { grant_type, code, redirect_uri, client_id, code_verifier, state }
        // Without it the endpoint returns 400 "Invalid request format".
        return try await exchange(
            code: code, verifier: verifier,
            state: cbState ?? state, redirectURI: redirectURI
        )
    }

    /// Counts every token POST. The CLI's flow makes EXACTLY one call per
    /// authorization code; if we ever see this counter > 1 for the same code,
    /// it means our callback listener fired twice (browser favicon, retry,
    /// etc.) and the second hit triggered an `invalid_grant` / `429` from
    /// Anthropic's code-replay defense. The fix is upstream (single-shot
    /// listener); the counter is here to make the bug observable.
    private nonisolated(unsafe) static var exchangeCount: Int = 0
    private static let exchangeCountLock = NSLock()

    static func exchange(code: String, verifier: String, state: String, redirectURI: String) async throws -> TokenResponse {
        exchangeCountLock.lock()
        exchangeCount += 1
        let n = exchangeCount
        exchangeCountLock.unlock()
        FileHandle.standardError.write(Data(
            "[oauth] POST token (call #\(n))\n".utf8
        ))

        var req = URLRequest(url: URL(string: tokenURL)!)
        req.httpMethod = "POST"
        // Anthropic's `platform.claude.com/v1/oauth/token` sits behind their
        // main API gateway, which speaks JSON only — the response shape
        // `{type:"error",error:{type:"invalid_request_error",message:...}}`
        // confirmed it. Sending application/x-www-form-urlencoded yields
        // 400 "Invalid request format" even with a perfectly formed body.
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        // `state` MUST be in the body — Anthropic's token endpoint validates
        // it server-side and 400s with "Invalid request format" otherwise.
        // Verified by reading `claude-code@1.0.0`'s cli.js `ijA()`.
        let payload: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
            "state": state,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        FileHandle.standardError.write(Data(
            "[oauth] token resp HTTP \(status)\n".utf8
        ))
        if status >= 400 {
            throw NSError(
                domain: "ClaudeOAuth", code: status,
                userInfo: [NSLocalizedDescriptionKey: "Token exchange failed (HTTP \(status))"]
            )
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// Exchange a refresh token for a new access/refresh token pair.
    ///
    /// Anthropic's OAuth access tokens live ~8 hours. Without this, users
    /// would need to re-OAuth every 8 hours and see "stuck on old data"
    /// when the token silently expired. Called by `UsageAPI.fetch()` when
    /// the stored token is near expiry.
    ///
    /// Anthropic may rotate the refresh_token itself on each use — the
    /// caller must persist whatever new refresh_token the response carries.
    static func refresh(refreshToken: String) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        FileHandle.standardError.write(Data(
            "[oauth] refresh HTTP \(status)\n".utf8
        ))
        if status >= 400 {
            throw NSError(
                domain: "ClaudeOAuth", code: status,
                userInfo: [NSLocalizedDescriptionKey: "Token refresh failed (HTTP \(status))"]
            )
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - PKCE

    private static func makeCodeVerifier() -> String {
        // RFC 7636: 43..128 chars from [A-Z a-z 0-9 - . _ ~]. CLI uses 64.
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private static func makeCodeChallenge(verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Localhost OAuth callback listener

/// Tiny one-shot HTTP/1.1 listener for the OAuth `?code=...` redirect.
///
/// Strict single-shot semantics:
///   * Browsers commonly open more than one TCP connection to a redirect host
///     (favicon prefetch, HTTP/1.1 keep-alive races, anti-prerender retries).
///     If we naively let multiple connections reach the parser we can resolve
///     the same `code` twice — Anthropic's token endpoint defends against
///     code-replay by returning `429 rate_limit_error`, which masquerades as
///     "wait and retry" but is actually permanent for that code.
///   * To avoid that, the moment we parse a valid `/callback?code=…` request
///     we (a) resolve the continuation, (b) cancel the listener so no further
///     newConnectionHandler invocations fire, and (c) drop any in-flight
///     incomplete connections.
///   * Connections that arrive BEFORE the valid one (favicon, HEAD probe…)
///     are answered politely and ignored if their path isn't `/callback` with
///     a `code` query param. They never touch the continuation.
final class OAuthCallbackServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "llmbar.oauth.callback")
    private var bound: UInt16 = 0
    private var continuation: CheckedContinuation<URL, Error>?
    private var resolved = false   // queue-isolated; set the moment we hand off a URL
    private var cancelled = false  // queue-isolated; prevents late resumes after cancel()

    /// Binds to a FIXED port on the loopback interface. Anthropic's authorize
    /// page redirects to whatever `redirect_uri` we sent, so the port has to
    /// be known up front. The CLI uses 54545; we match it so a stale Anthropic
    /// session record (port-bound) can't desync us.
    init(port: UInt16) throws {
        let p = NWParameters.tcp
        p.allowLocalEndpointReuse = true
        p.acceptLocalOnly = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "ClaudeOAuth", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Bad port \(port)"])
        }
        self.listener = try NWListener(using: p, on: nwPort)
        self.bound = port
    }

    /// Start listening; resolves with the bound port number once `.ready`.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            // Both stateUpdateHandler and newConnectionHandler run on `queue`
            // (NWListener guarantees serial dispatch on the started queue), so
            // a plain Bool guard is safe — no atomics needed.
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if !resumed, let p = self.listener.port?.rawValue {
                        resumed = true
                        self.bound = p
                        FileHandle.standardError.write(Data(
                            "[oauth] listener ready on 127.0.0.1:\(p)\n".utf8
                        ))
                        cont.resume(returning: p)
                    }
                case .failed(let e):
                    FileHandle.standardError.write(Data("[oauth] listener failed: \(e)\n".utf8))
                    if !resumed { resumed = true; cont.resume(throwing: e) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            listener.start(queue: queue)
        }
    }

    /// Waits for the browser to redirect back with an auth code.
    ///
    /// Caps the wait at `timeout` seconds so a user who closes the browser
    /// mid-flow isn't left with the UI stuck in `.waiting` forever — after
    /// the timeout the continuation resumes with a clear error and the user
    /// can retry. Also respects `cancel()` for user-initiated aborts.
    func waitForCallback(timeout: TimeInterval = 180) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                    guard let self else {
                        cont.resume(throwing: CancellationError()); return
                    }
                    self.queue.async {
                        if self.cancelled {
                            cont.resume(throwing: CancellationError())
                            return
                        }
                        self.continuation = cont
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NSError(
                    domain: "ClaudeOAuth", code: -7,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Sign-in timed out. Please try again."]
                )
            }
            guard let url = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return url
        }
    }

    /// User-initiated abort (Cancel button in LoginSheet, or sheet dismiss).
    /// Resumes the pending continuation with `CancellationError` so the
    /// Task in LoginSheet resolves promptly instead of waiting out the
    /// full timeout.
    func cancel() {
        queue.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.cancelled = true
            if let cont = self.continuation {
                self.continuation = nil
                cont.resume(throwing: CancellationError())
            }
        }
    }

    /// Awaits full cancellation. `listener.cancel()` returns immediately but
    /// the OS-level socket release is async — kicking off a second sign-in
    /// before `.cancelled` fires on the previous listener will hit
    /// EADDRINUSE on `bind(54545)`. So we replace the state handler and wait.
    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                if case .cancelled = state, !resumed {
                    resumed = true
                    cont.resume()
                }
            }
            listener.cancel()
        }
    }

    private func accept(_ conn: NWConnection) {
        // If we've already resolved, refuse new connections outright. Don't
        // even read — just close. (NWListener may still queue a few in flight
        // before our cancel propagates.)
        if resolved {
            FileHandle.standardError.write(Data("[oauth] dropping extra conn after resolved\n".utf8))
            conn.cancel()
            return
        }
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }

            // Always answer with a polite page so the browser tab doesn't
            // show "couldn't connect" — even for favicon / HEAD probes.
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><title>LLimit</title>
            <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;
            text-align:center;margin-top:20vh;color:#222}h1{font-weight:600}
            p{color:#666}</style></head><body>
            <h1>Sign-in complete</h1>
            <p>You can close this tab and return to LLimit.</p>
            </body></html>
            """
            let bodyData = Data(html.utf8)
            let header = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(bodyData.count)\r
            Cache-Control: no-store\r
            Connection: close\r
            \r

            """
            conn.send(content: Data(header.utf8) + bodyData,
                      completion: .contentProcessed { _ in conn.cancel() })

            // Parse "GET /path?... HTTP/1.1" out of the first line.
            guard let data,
                  let req = String(data: data, encoding: .utf8),
                  let firstLine = req.split(separator: "\r\n", omittingEmptySubsequences: false).first
            else { return }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else { return }
            let method = String(parts[0])
            let path = String(parts[1])
            FileHandle.standardError.write(Data("[oauth] conn \(method) \(path.split(separator: "?").first ?? "/")\n".utf8))

            guard let url = URL(string: "http://127.0.0.1:\(self.bound)\(path)") else { return }

            // Only treat a path with `code=` as the real callback. Ignore
            // favicon / random probes so they can't accidentally resolve.
            let hasCode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .contains(where: { $0.name == "code" || $0.name == "error" }) ?? false
            guard hasCode else { return }

            // Single-shot — flip the flag and hand off the URL. Don't cancel
            // the listener here: run()'s `await server.stop()` is the sole
            // canceller, and it waits for `.cancelled` to fire. If we cancel
            // here first, that state transition has already happened by the
            // time stop() installs its handler, and the await hangs forever.
            // Late connections (favicon, retries) are dropped at the top of
            // accept() via the `resolved` guard.
            if self.resolved { return }
            self.resolved = true
            self.continuation?.resume(returning: url)
            self.continuation = nil
        }
    }
}

/// Handle passed to `ClaudeOAuthLogin.run(session:)` so the caller (LoginSheet)
/// can abort an in-flight OAuth flow — e.g. when the user clicks "Cancel
/// sign-in" or dismisses the sheet after closing the browser tab.
///
/// Holds a weak reference to the currently-bound `OAuthCallbackServer` and
/// forwards `cancel()` through to it. `detach()` runs after `run()` returns
/// (success or failure) so a stale session can't cancel a future flow.
actor ClaudeOAuthSession {
    private weak var server: OAuthCallbackServer?

    init() {}

    func attach(_ s: OAuthCallbackServer) {
        server = s
    }

    func detach() {
        server = nil
    }

    func cancel() {
        server?.cancel()
    }
}
