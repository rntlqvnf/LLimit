import Foundation

@MainActor
final class AccountStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var pollIntervalSeconds: Int = 300

    private let storeURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let supportDir = appSupport.appendingPathComponent("LLMBar", isDirectory: true)
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        storeURL = supportDir.appendingPathComponent("accounts.json")

        // Migrate legacy LLMUsageTracker store if present.
        let legacy = appSupport.appendingPathComponent("LLMUsageTracker/accounts.json")
        if !fm.fileExists(atPath: storeURL.path),
           fm.fileExists(atPath: legacy.path) {
            try? fm.copyItem(at: legacy, to: storeURL)
        }

        load()
        if accounts.isEmpty { seedDefaults() }
        autoAddMissingDefaults()
    }

    func add(_ account: Account) {
        accounts.append(account)
        save()
    }

    func remove(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        save()
    }

    func update(_ account: Account) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i] = account
            save()
        }
    }

    func setPollInterval(_ seconds: Int) {
        pollIntervalSeconds = max(60, seconds)
        save()
    }

    private struct Snapshot: Codable {
        var accounts: [Account]
        var pollIntervalSeconds: Int
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return
        }
        accounts = snap.accounts
        pollIntervalSeconds = snap.pollIntervalSeconds
    }

    private func save() {
        let snap = Snapshot(accounts: accounts, pollIntervalSeconds: pollIntervalSeconds)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(snap) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private func autoAddMissingDefaults() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let codexDir = home + "/.codex"
        let hasCodexAccount = accounts.contains { $0.provider == .codex }
        if !hasCodexAccount && FileManager.default.fileExists(atPath: codexDir) {
            accounts.append(Account(name: "Codex (default)", provider: .codex, configDir: codexDir))
            save()
        }
    }

    private func seedDefaults() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let claudeDir = home + "/.claude"
        let codexDir = home + "/.codex"
        if FileManager.default.fileExists(atPath: claudeDir) {
            accounts.append(Account(name: "Claude (default)", provider: .claude, configDir: claudeDir))
        }
        if FileManager.default.fileExists(atPath: codexDir) {
            accounts.append(Account(name: "Codex (default)", provider: .codex, configDir: codexDir))
        }
        save()
    }
}
