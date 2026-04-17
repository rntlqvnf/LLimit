import SwiftUI
import AppKit

struct MenuContentView: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var refresher: RefreshCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 14)

            if store.accounts.isEmpty {
                Text("No accounts. Open Settings to add one.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(14)
            } else {
                VStack(spacing: 10) {
                    ForEach(store.accounts) { account in
                        AccountCard(account: account,
                                    state: refresher.states[account.id] ?? .idle)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            Divider().padding(.horizontal, 14)
            footer
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .foregroundStyle(.tint)
            Text("LLM Usage").font(.headline)
            Spacer()
            if let date = refresher.lastRefreshedAt {
                Text(date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct AccountCard: View {
    let account: Account
    let state: UsageState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: account.provider == .claude
                      ? "sparkle"
                      : "chevron.left.forwardslash.chevron.right")
                    .font(.caption)
                    .foregroundStyle(accent)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(accent.opacity(0.15))
                    )
                Text(account.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(account.provider.displayName.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }

            content
        }
        .padding(12)
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
        account.provider == .claude ? .orange : .cyan
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
            return "\(Int((p * 100).rounded()))%"
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
