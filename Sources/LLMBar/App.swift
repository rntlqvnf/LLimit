import SwiftUI
import AppKit

@main
struct LLMBarApp: App {
    @StateObject private var accountStore: AccountStore
    @StateObject private var refresher: RefreshCoordinator

    init() {
        let store = AccountStore()
        let coord = RefreshCoordinator(store: store)
        _accountStore = StateObject(wrappedValue: store)
        _refresher = StateObject(wrappedValue: coord)
        NSApplication.shared.setActivationPolicy(.accessory)
        UsageNotifier.shared.requestAuthorization()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(accountStore)
                .environmentObject(refresher)
        } label: {
            MenuBarLabel()
                .environmentObject(accountStore)
                .environmentObject(refresher)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(accountStore)
                .environmentObject(refresher)
        }
    }
}
