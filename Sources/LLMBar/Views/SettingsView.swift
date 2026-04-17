import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var refresher: RefreshCoordinator

    @State private var loginAccount: Account?

    var body: some View {
        TabView {
            AccountsTab(loginAccount: $loginAccount)
                .tabItem { Label("Accounts", systemImage: "person.2") }
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 620, height: 520)
        .sheet(item: $loginAccount) { account in
            LoginSheet(account: account) {
                Task { await refresher.refresh(account) }
            }
        }
    }
}

// MARK: - Accounts

private struct AccountsTab: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var refresher: RefreshCoordinator
    @Binding var loginAccount: Account?

    @State private var selection: UUID?
    @State private var draft: Account?
    @State private var isAdding = false

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 200, maxWidth: 240)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selection) { _, new in loadDraft(for: new) }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.accounts) { acc in
                    HStack(spacing: 8) {
                        Image(systemName: acc.provider == .claude
                              ? "sparkle"
                              : "chevron.left.forwardslash.chevron.right")
                            .foregroundStyle(acc.provider == .claude ? .orange : .cyan)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(acc.name).font(.body)
                            Text(acc.provider.displayName)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .tag(acc.id)
                }
            }
            Divider()
            HStack(spacing: 6) {
                Button {
                    startAdd()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                Button {
                    if let id = selection,
                       let acc = store.accounts.first(where: { $0.id == id }) {
                        store.remove(acc)
                        selection = nil
                        draft = nil
                    }
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let draft = Binding($draft) {
            EditForm(
                draft: draft,
                isAdding: isAdding,
                onSave: { save() },
                onCancel: { self.draft = nil; self.isAdding = false },
                onLogin: { acc in loginAccount = acc }
            )
            .padding()
        } else {
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("Select an account or click + to add one")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func startAdd() {
        isAdding = true
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        draft = Account(name: "", provider: .claude, configDir: home + "/.claude")
        selection = nil
    }

    private func save() {
        guard var d = draft else { return }
        if d.name.trimmingCharacters(in: .whitespaces).isEmpty {
            d.name = "\(d.provider.displayName) (\(URL(fileURLWithPath: d.configDir).lastPathComponent))"
        }
        if isAdding {
            store.add(d)
            selection = d.id
            isAdding = false
        } else {
            store.update(d)
        }
        draft = nil
        Task { await refresher.refresh(d) }
    }

    private func loadDraft(for id: UUID?) {
        guard let id, let acc = store.accounts.first(where: { $0.id == id }) else {
            if !isAdding { draft = nil }
            return
        }
        isAdding = false
        draft = acc
    }

}

private struct EditForm: View {
    @Binding var draft: Account
    let isAdding: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    let onLogin: (Account) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isAdding ? "New account" : "Edit account")
                .font(.headline)

            Form {
                TextField("Name", text: $draft.name,
                          prompt: Text("e.g. Work Claude"))
                Picker("Provider", selection: $draft.provider) {
                    ForEach(Provider.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .onChange(of: draft.provider) { _, p in
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    if draft.configDir.hasSuffix("/.claude") || draft.configDir.hasSuffix("/.codex") {
                        draft.configDir = home + (p == .claude ? "/.claude" : "/.codex")
                    }
                }
                HStack {
                    TextField("Config dir", text: $draft.configDir,
                              prompt: Text("~/.claude"))
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            draft.configDir = url.path
                        }
                    }
                }
            }

            Spacer()

            HStack {
                if !isAdding {
                    Button("Login…") { onLogin(draft) }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                Button(isAdding ? "Add" : "Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.configDir.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var refresher: RefreshCoordinator

    @AppStorage("warnAtPercent") private var warnAtPercent: Double = 80
    @AppStorage("showResetTimes") private var showResetTimes: Bool = true
    @AppStorage("compactMenuBar") private var compactMenuBar: Bool = false
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Refresh") {
                Stepper(value: Binding(
                    get: { store.pollIntervalSeconds / 60 },
                    set: { store.setPollInterval($0 * 60) }
                ), in: 1...120) {
                    HStack {
                        Text("Auto-refresh every")
                        Text("\(store.pollIntervalSeconds / 60) min")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button {
                        Task { await refresher.refreshAll() }
                    } label: {
                        Label("Refresh now", systemImage: "arrow.clockwise")
                    }
                    if let last = refresher.lastRefreshedAt {
                        Text("last: \(last, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Display") {
                Toggle("Show reset times under each bar", isOn: $showResetTimes)
                Toggle("Compact menu bar (icon only)", isOn: $compactMenuBar)
                LabeledContent("Warn at") {
                    HStack {
                        Slider(value: $warnAtPercent, in: 50...95, step: 5)
                            .frame(maxWidth: 200)
                        Text("\(Int(warnAtPercent))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { v in launchAtLogin = v; LaunchAtLogin.setEnabled(v) }
                ))
            }

            Section("Storage") {
                LabeledContent("Config") {
                    Text(configPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(configPath, inFileViewerRootedAtPath: "")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var configPath: String {
        let fm = FileManager.default
        let url = (try? fm.url(for: .applicationSupportDirectory,
                               in: .userDomainMask, appropriateFor: nil, create: false))?
            .appendingPathComponent("LLMBar/accounts.json")
        return url?.path ?? "~/Library/Application Support/LLMBar/accounts.json"
    }
}
