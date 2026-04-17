import SwiftUI
import AppKit

struct LoginSheet: View {
    let account: Account
    var onFinished: (() -> Void)? = nil

    @StateObject private var runner = CLILoginRunner()
    @Environment(\.dismiss) private var dismiss
    @State private var detectedLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in: \(account.name)").font(.headline)
                Text("\(account.provider.displayName) · \(account.configDir)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Steps").font(.subheadline.weight(.semibold))
                Text("1. Terminal opens with the login command running.")
                Text("2. Sign in via the browser tab that opens.")
                Text("3. If a code is shown, paste it into the Terminal and press Return.")
                Text("4. This window closes itself once login is detected.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if !runner.commandLine.isEmpty {
                Text(runner.commandLine)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }

            statusView

            HStack {
                Button("Reopen Terminal") { runner.launch(account: account) }
                    .controlSize(.small)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Done") {
                    onFinished?()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 540)
        .onAppear { runner.launch(account: account) }
        .task {
            while !Task.isCancelled && !detectedLogin {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if await CLILoginRunner.isLoggedIn(account: account) {
                    detectedLogin = true
                    if account.provider == .claude {
                        do {
                            try ClaudeAuthSource.snapshotKeychain(into: account.configDir)
                        } catch {
                            FileHandle.standardError.write(
                                Data("[claude] snapshot failed: \(error)\n".utf8)
                            )
                        }
                    }
                    onFinished?()
                    dismiss()
                    return
                }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if detectedLogin {
            Label("✓ login detected", systemImage: "checkmark.seal.fill")
                .font(.callout).foregroundStyle(.green)
        } else {
            switch runner.status {
            case .idle:
                EmptyView()
            case .launched:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("waiting for sign-in to complete…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
            }
        }
    }
}
