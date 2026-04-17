import Foundation
import AppKit

@MainActor
final class CLILoginRunner: ObservableObject {
    @Published var status: Status = .idle
    @Published var commandLine: String = ""

    enum Status: Equatable {
        case idle
        case launched
        case error(String)
    }

    func launch(account: Account) {
        let (binary, args, envKey) = command(for: account.provider)
        guard let binPath = Self.resolveBinary(binary) else {
            status = .error("\(binary) not found in PATH")
            return
        }

        try? FileManager.default.createDirectory(
            atPath: account.configDir,
            withIntermediateDirectories: true
        )

        let quotedDir = Self.shQuote(account.configDir)
        let quotedBin = Self.shQuote(binPath)
        let quotedArgs = args.map(Self.shQuote).joined(separator: " ")
        // Codex spins a local OAuth callback on port 1455; if a previous
        // run left it bound, the new login dies with "port in use".
        // Best-effort free it before launching.
        let preflight: String = (account.provider == .codex)
            ? "pids=$(lsof -ti tcp:1455 2>/dev/null); " +
              "if [ -n \"$pids\" ]; then echo 'freeing port 1455...'; " +
              "kill $pids 2>/dev/null; sleep 1; " +
              "kill -9 $(lsof -ti tcp:1455 2>/dev/null) 2>/dev/null; fi; "
            : ""
        let inner = """
        clear; \(preflight)export \(envKey)=\(quotedDir); \(quotedBin) \(quotedArgs); ec=$?; \
        echo; if [ $ec -eq 0 ]; then echo '✓ login finished. you can close this window.'; \
        else echo \"✗ exited with code $ec\"; fi; \
        printf 'press return to close...'; read _
        """
        commandLine = "\(envKey)=\(account.configDir) \(binPath) \(args.joined(separator: " "))"

        let osa = """
        tell application "Terminal"
            activate
            do script \(Self.applescriptQuote(inner))
        end tell
        """

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", osa]
        do {
            try p.run()
            status = .launched
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func command(for provider: Provider) -> (String, [String], String) {
        switch provider {
        case .claude:
            return ("claude", ["auth", "login"], "CLAUDE_CONFIG_DIR")
        case .codex:
            return ("codex", ["login"], "CODEX_HOME")
        }
    }

    static func resolveBinary(_ name: String) -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/Applications/cmux.app/Contents/Resources/bin/\(name)",
        ]
        for c in candidates
            where FileManager.default.isExecutableFile(atPath: c) && !isShellScript(c) {
            return c
        }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-l", "-c", "command -v \(name)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    static func isShellScript(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 2)
        return head == Data("#!".utf8)
    }

    static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func applescriptQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func isLoggedIn(account: Account) async -> Bool {
        switch account.provider {
        case .claude:
            let out = await runCapture("claude", ["auth", "status"], env: ["CLAUDE_CONFIG_DIR": account.configDir])
            struct S: Decodable { let loggedIn: Bool }
            if let data = out.data(using: .utf8),
               let s = try? JSONDecoder().decode(S.self, from: data) {
                return s.loggedIn
            }
            return false
        case .codex:
            let out = await runCapture("codex", ["login", "status"], env: ["CODEX_HOME": account.configDir])
            return out.lowercased().contains("logged in")
        }
    }

    static func runCapture(_ binary: String, _ args: [String], env: [String: String]) async -> String {
        guard let binPath = resolveBinary(binary) else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binPath)
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return ""
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global().async {
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                cont.resume(returning: out.isEmpty ? err : out)
            }
        }
    }
}
