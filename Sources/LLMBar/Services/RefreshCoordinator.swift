import Foundation
import Combine

@MainActor
final class RefreshCoordinator: ObservableObject {
    @Published var states: [UUID: UsageState] = [:]
    @Published var lastRefreshedAt: Date?

    private let store: AccountStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(store: AccountStore) {
        self.store = store
        scheduleTimer()
        store.$pollIntervalSeconds
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleTimer() }
            .store(in: &cancellables)
        Task { await refreshAll() }
    }

    func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(60, store.pollIntervalSeconds))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
    }

    func refreshAll() async {
        let accounts = store.accounts
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { @MainActor in await self.refresh(account) }
            }
        }
        lastRefreshedAt = Date()
    }

    func refresh(_ account: Account) async {
        states[account.id] = .loading
        do {
            let snap = try await api(for: account).fetch(account: account)
            states[account.id] = .loaded(snap)
            UsageNotifier.shared.evaluate(account: account, snapshot: snap)
        } catch {
            states[account.id] = .error(error.localizedDescription)
        }
    }

    private func api(for account: Account) -> UsageAPI {
        switch account.provider {
        case .claude: return AnthropicUsageAPI()
        case .codex:  return OpenAIUsageAPI()
        }
    }
}
