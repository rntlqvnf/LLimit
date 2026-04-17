# LLMBar

A native macOS menu-bar app that shows **how much of your Claude Code and
Codex usage windows you've burned through** — at a glance, across multiple
accounts, without leaving the keyboard.

> Inspired by [steipete/CodexBar](https://github.com/steipete/CodexBar),
> but reuses your existing `claude` / `codex` CLI logins instead of
> requiring a separate sign-in flow.

---

## Install

### From GitHub Releases (recommended)

1. Grab the latest `LLMBar-<version>.zip` from the
   [Releases page](https://github.com/rntlqvnf/LLMBar/releases).
2. Unzip and drag `LLMBar.app` into `/Applications`.
3. The first launch is ad-hoc signed; if Gatekeeper complains, right-click →
   **Open** → **Open** to bypass once.

### Build from source

Requires macOS 14+ and Xcode 15 / Swift 5.9.

```sh
git clone https://github.com/rntlqvnf/LLMBar.git
cd LLMBar
Scripts/package_app.sh                  # → build/release/LLMBar.app
open build/release/LLMBar.app
```

For a versioned, zipped artifact:

```sh
Scripts/package_app.sh 0.2.0 zip        # → build/release/LLMBar-0.2.0.zip
```

---

## Features

- **Live menu-bar icon** — two stacked progress bars (5-hour / weekly) plus an
  optional headline percent. Color escalates orange ≥70%, red ≥90%.
- **Multiple accounts at once** — list view up to 3 accounts, automatic
  2-column grid above that. Supports any mix of Claude and Codex configs.
- **Real plan-relative percentages**
  - Claude: calls `https://api.anthropic.com/api/oauth/usage` with your
    existing OAuth token (`5h`, `7d`, `7d opus`, `7d sonnet`).
  - Codex: parses `~/.codex/sessions/**/*.jsonl` `token_count` events for the
    primary (5h) and secondary (weekly) rate-limit blocks.
- **Identity at a glance** — surfaces email + plan tier (`max plan`,
  `plus plan`, …) under each account name.
- **Threshold notifications** — configurable warn-at percentage; one
  notification per window per reset cycle.
- **Launch at login** — toggle in General settings (uses
  `SMAppService.mainApp`).
- **Per-account login flow** — opens a Terminal running
  `CLAUDE_CONFIG_DIR=… claude auth login` (or the Codex equivalent), polls
  for completion, then snapshots the credential into the account directory
  so multiple Claude accounts coexist without overwriting each other.

---

## How it reads usage

| Provider | Source                                                                  |
| -------- | ----------------------------------------------------------------------- |
| Claude   | `GET https://api.anthropic.com/api/oauth/usage` with the OAuth token    |
| Codex    | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (`token_count` events)   |
| Auth     | `Claude Code-credentials` keychain (snapshotted) and `~/.codex/auth.json` |

LLMBar never sends data anywhere except to the same Anthropic OAuth
endpoint the Claude CLI itself uses.

---

## Releasing (maintainers)

```sh
Scripts/release.sh 0.2.0 "What's new in this release"
```

The script verifies a clean tree, builds a universal `.app`, ad-hoc signs it,
zips it, tags `v0.2.0`, pushes the tag, and uploads the zip via `gh release
create`. No notarization yet — users get a Gatekeeper warning on first launch.

---

## License

MIT. See `LICENSE` (TBD).
