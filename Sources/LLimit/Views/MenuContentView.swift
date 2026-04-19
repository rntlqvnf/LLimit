import SwiftUI
import AppKit

struct MenuContentView: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var refresher: RefreshCoordinator
    @Environment(\.openSettings) private var openSettings

    @AppStorage("popoverMode") private var popoverMode: PopoverMode = .summary

    enum PopoverMode: String, CaseIterable, Identifiable {
        case summary
        case detailed
        var id: String { rawValue }
        var systemImage: String {
            self == .summary ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
        }
    }

    private var width: CGFloat { popoverMode == .summary ? 460 : 540 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 16)

            if store.accounts.isEmpty {
                Text("No accounts. Open Settings to add one.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(16)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.accounts) { account in
                        if popoverMode == .summary {
                            AccountRowSummary(
                                account: account,
                                state: refresher.states[account.id] ?? .idle
                            )
                        } else {
                            AccountCardDetailed(
                                account: account,
                                state: refresher.states[account.id] ?? .idle
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Divider().padding(.horizontal, 16)
            footer
        }
        .frame(width: width)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .foregroundStyle(.tint)
                .font(.title3)
            Text("LLimit").font(.headline)
            Spacer()

            Picker("", selection: $popoverMode) {
                ForEach(PopoverMode.allCases) { m in
                    Image(systemName: m.systemImage).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 80)

            if let date = refresher.lastRefreshedAt {
                Text(date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                Task { await refresher.refreshAll() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Spacer()
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Summary row (one line per account, every window inline)

private struct AccountRowSummary: View {
    let account: Account
    let state: UsageState

    var body: some View {
        HStack(spacing: 10) {
            providerBadge

            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if needsLoginToSeparate {
                    Text("sign in to separate accounts")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if let id = identityLine {
                    Text(id)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: 150, alignment: .leading)

            // Inline mini-bars: one column per window, fills remaining space.
            stateContent

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var providerBadge: some View {
        ProviderBadge(provider: account.provider, size: 22)
    }

    private var accent: Color {
        ProviderIcon(provider: account.provider).color
    }

    private var identityLine: String? {
        guard case .loaded(let snap) = state else { return nil }
        var parts: [String] = []
        if let e = snap.email { parts.append(e) }
        if let p = snap.planLabel { parts.append(p) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Claude accounts share a global keychain entry. Until the user signs
    /// in *through LLimit* (which writes a per-account snapshot), every
    /// Claude row sees whichever credential the CLI logged in last.
    private var needsLoginToSeparate: Bool {
        account.provider == .claude
            && !ClaudeAuthSource.hasSnapshot(for: account.id)
    }

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .idle:
            Text("—").font(.caption).foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("loading…").font(.caption).foregroundStyle(.secondary)
            }
        case .loaded(let snap):
            if snap.windows.isEmpty {
                Text("no usage windows")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    ForEach(snap.windows, id: \.label) { w in
                        MiniWindow(window: w, accent: accent)
                    }
                }
            }
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }
}

private struct MiniWindow: View {
    let window: UsageWindow
    let accent: Color

    private var pct: Double {
        max(0, min(1, window.usedPercent ?? 0))
    }
    private var color: Color {
        if pct >= 0.9 { return .red }
        if pct >= 0.7 { return .orange }
        return accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(shortLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 2)
                Text("\(Int(((1 - pct) * 100).rounded()))% left")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            UsageBar(progress: pct, color: color)
                .frame(height: 5)
        }
        .frame(minWidth: 64, idealWidth: 90)
    }

    /// Compact, fixed-width-ish labels so 4 windows fit on one row even on
    /// the summary view. `7d opus` is a model-specific weekly cap — drop the
    /// redundant `7D` prefix.
    private var shortLabel: String {
        let l = window.label.lowercased()
        if l.contains("opus") { return "OPUS" }
        return window.label.uppercased()
    }
}

// MARK: - Detailed card (full bars + reset times + note)

private struct AccountCardDetailed: View {
    let account: Account
    let state: UsageState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProviderBadge(provider: account.provider, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name)
                        .font(.subheadline.weight(.semibold))
                    if needsLoginToSeparate {
                        Text("sign in to separate accounts")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else if let identity = identityLine {
                        Text(identity)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Text(account.provider.displayName.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }

            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var accent: Color {
        ProviderIcon(provider: account.provider).color
    }

    private var identityLine: String? {
        guard case .loaded(let snap) = state else { return nil }
        var parts: [String] = []
        if let e = snap.email { parts.append(e) }
        if let p = snap.planLabel { parts.append(p) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var needsLoginToSeparate: Bool {
        account.provider == .claude
            && !ClaudeAuthSource.hasSnapshot(for: account.id)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            Text("—").font(.caption).foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("loading…").font(.caption).foregroundStyle(.secondary)
            }
        case .loaded(let snap):
            if snap.windows.isEmpty {
                Text("no usage in tracked windows")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(snap.windows, id: \.label) { w in
                        WindowRow(window: w, accent: accent)
                    }
                }
            }
            if let note = snap.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

private struct WindowRow: View {
    let window: UsageWindow
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(windowTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(rightText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(barColor)
            }
            UsageBar(progress: progress, color: barColor)
                .frame(height: 6)
            HStack {
                if let resets = window.resetsAt, resets > Date() {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                    Text("resets in \(formatRelative(resets))")
                        .font(.caption2)
                }
                Spacer()
            }
            .foregroundStyle(.tertiary)
        }
    }

    private var windowTitle: String {
        switch window.label {
        case "5h": return "5-hour window"
        case "7d": return "Weekly window"
        default: return window.label + " window"
        }
    }

    private var progress: Double {
        if let p = window.usedPercent { return max(0, min(1, p)) }
        if let t = window.tokens {
            let cap = softCap(label: window.label)
            return min(1, Double(t) / cap)
        }
        return 0
    }

    private var rightText: String {
        if let p = window.usedPercent {
            return "\(Int(((1 - p) * 100).rounded()))% left"
        }
        if let t = window.tokens {
            return "\(formatTokens(t)) tok"
        }
        return ""
    }

    private var barColor: Color {
        let p = progress
        if p >= 0.9 { return .red }
        if p >= 0.7 { return .orange }
        return accent
    }

    private func softCap(label: String) -> Double {
        switch label {
        case "5h": return 2_000_000
        case "7d": return 25_000_000
        default: return 1_000_000
        }
    }
}

private struct UsageBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.85), color],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(progress > 0 ? 4 : 0, geo.size.width * progress))
            }
        }
    }
}

private func formatRelative(_ date: Date) -> String {
    let secs = Int(date.timeIntervalSinceNow)
    if secs < 60 { return "<1m" }
    if secs < 3600 { return "\(secs / 60)m" }
    if secs < 86400 {
        let h = secs / 3600
        let m = (secs % 3600) / 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }
    let d = secs / 86400
    let h = (secs % 86400) / 3600
    return h > 0 ? "\(d)d \(h)h" : "\(d)d"
}
