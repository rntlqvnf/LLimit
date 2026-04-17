import SwiftUI

/// The live status indicator in the system menu bar. Picks the most-loaded
/// window across all accounts and renders two stacked bars (5h / 7d) plus
/// an optional percent label.
struct MenuBarLabel: View {
    @EnvironmentObject var store: AccountStore
    @EnvironmentObject var refresher: RefreshCoordinator

    @AppStorage("compactMenuBar") private var compactMenuBar: Bool = false

    var body: some View {
        let summary = highestLoad()
        HStack(spacing: 4) {
            BarsIcon(short: summary.fiveHour, long: summary.sevenDay,
                     color: summary.color)
                .frame(width: 18, height: 14)
            if !compactMenuBar, let pct = summary.headlinePercent {
                Text("\(pct)%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        }
    }

    private struct Summary {
        let fiveHour: Double?
        let sevenDay: Double?
        let headlinePercent: Int?
        let color: Color
    }

    private func highestLoad() -> Summary {
        var best5: Double? = nil
        var best7: Double? = nil
        var headline: Double? = nil

        for account in store.accounts {
            guard case .loaded(let snap) = refresher.states[account.id] ?? .idle else {
                continue
            }
            for w in snap.windows {
                guard let p = w.usedPercent else { continue }
                let label = w.label.lowercased()
                if label.contains("5h") || label.contains("5-hour") {
                    if best5 == nil || p > best5! { best5 = p }
                } else if label.contains("7d") || label.contains("week") {
                    if best7 == nil || p > best7! { best7 = p }
                }
                if headline == nil || p > headline! { headline = p }
            }
        }

        let pct = headline.map { Int(($0 * 100).rounded()) }
        let color: Color = {
            guard let h = headline else { return .secondary }
            if h >= 0.9 { return .red }
            if h >= 0.7 { return .orange }
            return .primary
        }()
        return Summary(fiveHour: best5, sevenDay: best7,
                       headlinePercent: pct, color: color)
    }
}

private struct BarsIcon: View {
    let short: Double?
    let long: Double?
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let barHeight: CGFloat = 4
            let gap: CGFloat = 3
            let totalH = barHeight * 2 + gap
            let topY = (h - totalH) / 2

            ZStack(alignment: .topLeading) {
                bar(width: w, value: short, y: topY, height: barHeight)
                bar(width: w, value: long, y: topY + barHeight + gap, height: barHeight)
            }
        }
    }

    @ViewBuilder
    private func bar(width: CGFloat, value: Double?, y: CGFloat, height: CGFloat) -> some View {
        let v = max(0, min(1, value ?? 0))
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color.opacity(0.25))
                .frame(width: width, height: height)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: max(value == nil ? 0 : 1, width * v), height: height)
        }
        .offset(y: y)
    }
}
