![Agents Deck](screenshots/ss1.png)

# Agents Deck

Agents Deck is a small, local-only macOS menu bar app for monitoring verified Claude Code, Codex, and Antigravity CLI subscription usage.

It shows each provider's verified usage windows with their real durations, reset times, provider-supplied session cost or Codex credit information, and freshness. There is no Agents Deck account, backend, telemetry, cloud sync, or App Store dependency.

> Agents Deck is an independent open-source project. It is not affiliated with Anthropic, OpenAI, or Google.

## Download and install

1. Download `Agents-Deck-1.3.1.dmg` and its `.sha256` file from the latest [GitHub Release](https://github.com/vulonviing/agents-deck/releases/latest).
2. Optionally verify the download:

   ```sh
   shasum -a 256 -c Agents-Deck-1.3.1.sha256
   gh attestation verify Agents-Deck-1.3.1.dmg --repo vulonviing/agents-deck
   ```

3. Open the DMG and drag **Agents Deck** to **Applications**.
4. Try to open Agents Deck once. This free build is ad-hoc signed and is not Apple-notarized, so macOS will block the first launch.
5. Open **System Settings → Privacy & Security**, scroll to Security, click **Open Anyway**, then confirm **Open**.

Do not disable Gatekeeper globally. The override applies only to the exact app build you approved. Apple explains this flow in [Open apps safely on your Mac](https://support.apple.com/102445).

## Manual updates

Agents Deck does not contact GitHub or run an automatic updater. To update:

1. Quit Agents Deck from the menu bar icon's right-click menu.
2. Download and verify the new DMG from GitHub Releases.
3. Drag the new **Agents Deck** into **Applications** and choose **Replace**.
4. Use **Open Anyway** again if macOS requests it for the new download.

The bundle identifier remains stable, and application data under `~/Library/Application Support/Agents Deck/` is not stored inside the app bundle, so replacing the app preserves verified history and diagnostics.

## Requirements

- macOS 26 or later
- At least one of:
  - [Claude Code](https://code.claude.com/docs/en/overview)
  - [OpenAI Codex CLI](https://developers.openai.com/codex/cli)
  - [Google Antigravity CLI](https://www.antigravity.google/docs/getting-started?tab=cli)
- An individual subscription with usage data available to at least one of these official CLIs

## Build from source

Building requires a full Xcode installation that supports macOS 26 and Swift 6. Command Line Tools alone are not enough.

1. Clone the repository.
2. Open `AgentsDeck.xcodeproj` in Xcode.
3. Select the shared `AgentsDeck` scheme and the `My Mac` destination.
4. Press **Run**.
5. Complete the local setup guide. You can configure any combination of Claude, Codex, and Antigravity.

The command-line build check is:

```sh
xcodebuild -project AgentsDeck.xcodeproj -scheme AgentsDeck -destination 'platform=macOS' build
```

## How usage data is obtained

Agents Deck has no backend, user account, analytics endpoint, or telemetry collector. It launches the provider-installed command-line tools locally and normalizes only verified usage fields. Those CLIs may communicate with their own official provider services as they normally do; Agents Deck itself does not proxy that traffic through an Agents Deck server.

### Claude

Agents Deck checks login state with `claude auth status --json`. If login is required, the setup guide copies this official command and opens Terminal:

```sh
claude auth login --claudeai
```

Agents Deck refreshes Claude's built-in `/usage` command at startup, on popover/manual refresh, and on a user-selected randomized cadence. The available ranges are 1–3, 3–5, and 4–6 minutes; each provider receives an independent delay and the default is 1–3 minutes. This is a local slash command, not a model prompt, so the app does not send synthetic messages to consume usage. The command runs with tools and customizations disabled; its bounded rendered output is normalized in memory and never logged or stored raw.

Claude also exposes subscription limits through its documented status-line JSON. With explicit permission, the optional bridge adds immediate post-response updates and session cost. Agents Deck:

- backs up `~/.claude/settings.json`;
- merges a small bridge command without replacing unrelated settings;
- continues invoking an existing status-line command;
- extracts only `rate_limits` and `cost.total_cost_usd`;
- writes a private, sanitized local snapshot;
- restores the previous setting only when doing so cannot overwrite a later user change.

If the bridge has not produced data yet, the `/usage` probe can still provide verified windows. Session cost remains unavailable until Claude reports it through the status line.

The Claude detail page also reads Claude Code's own local `stats-cache.json` in read-only mode. It shows an explicitly **Local** and approximate Overview/Models view with all-time, seven-day, and thirty-day aggregates. Only daily counts, aggregate input/output model tokens, streak inputs, peak hour, and longest-session duration are allowlisted. Raw JSON, cost and cache-token fields, session identifiers, and unknown fields are discarded.

Agents Deck does not identify which model, effort, or thinking configuration produced a particular Claude session. It never reads conversation transcripts, and it never requests an organization Admin API key.

### Codex

Agents Deck starts one `codex app-server` child process and uses its documented JSONL protocol. It checks the current account, opens the official ChatGPT login URL when requested, consumes rate-limit update notifications, and uses the same independently randomized fallback cadence selected for Claude.

The Codex detail page reads the app-server `account/usage/read` summary and daily buckets, then renders Daily, Weekly, and Cumulative views. Hovering a day or weekly bar shows its exact period and token count. Only the latest normalized account snapshot is cached locally; raw JSON is discarded.

The same detail page shows the available reset-credit count and nearest provider-supplied expiry from `account/rateLimits/read`. The client uses a closed allowlist containing `initialize`, `account/read`, `account/rateLimits/read`, `account/usage/read`, and the explicit login flow. It deliberately cannot represent or send `account/rateLimitResetCredit/consume`, so Agents Deck never redeems a reset credit. It does not use thread-list/read calls to infer model activity and never reads conversation contents, Codex auth files, or tokens.

Codex window durations are supplied by app-server and may differ by account. Agents Deck labels the actual duration and uses the shortest verified window for the card gauge. If Codex supplies only a seven-day window, the card still shows it; the menu-bar percentage remains unavailable unless a verified window shorter than seven days exists. Billing is shown only when app-server supplies an individual monthly limit or credit balance. Otherwise the card says `Cost · Not provided` rather than estimating money from tokens.

### Antigravity

Agents Deck runs the official CLI's read-only `agy -p "/usage" --output-format json` command once per refresh. Google's [CLI changelog](https://www.antigravity.google/docs/changelog?tab=cli) says print-mode `/usage` does not start an agent turn or spend model quota. Its bounded output is reduced in memory to the Gemini 4 Argon, Gemini Models, and Claude and GPT Models quota groups. The panel shows **used** percentage (`100 − remaining`) for each available five-hour or weekly limit, provider-supplied reset times, and explicit `Disabled` states. Missing values stay `--`.

Antigravity refreshes on startup, panel open, manual refresh, and an independent randomized deadline within the selected cadence. Sign in through `agy` in Terminal if needed. Agents Deck does not read Antigravity credentials, transcripts, or settings, and does not install a status-line bridge.

## Menu bar interaction

- Left-click the menu bar item to open a resizable usage panel. Drag a panel edge or corner to resize it; the last size is restored on the next open.
- Click a Claude or Codex ring or metric row to select its window; the five-hour window is the default. Click an Antigravity metric row to select it, and drag a group heading to reorder its quota groups. Each Mac remembers its chosen order locally.
- Use the provider menu beside Refresh to show any nonempty combination of Claude, Codex, and Antigravity in the menu bar. Each percentage follows that provider card's selected window; Antigravity defaults to Gemini 4 Argon's weekly limit.
- Click a provider card's logo or name to open its detail page. All providers show connection diagnostics. Codex additionally shows verified token activity and read-only reset-credit availability. Claude shows separately labelled local aggregate activity and aggregate model totals; it never attributes a model or reasoning effort to a session. Agents Deck never inspects threads or conversation contents.
- Use the timer menu to choose a 1–3, 3–5, or 4–6 minute automatic refresh range. Display mode, cadence, selected windows, and panel size are restored after relaunch.
- Hover the center percentage to see the selected window's name.
- Hover any interactive control to see subtle motion and an action-oriented tooltip. Reduce Motion disables the transform without removing the tooltip or focus indication.
- Right-click the menu bar item for **Settings…** and **Quit Agents Deck**.

## Privacy

Agents Deck stores only normalized provider usage, notification receipts, preferences, and redacted technical events. It never stores prompts, responses, source code, diffs, repository paths, transcript paths, provider session IDs, credentials, or raw provider payloads.

Application-owned data stays under:

```text
~/Library/Application Support/Agents Deck/
```

- Verified usage history is retained for 365 days.
- History is stored in `History/History.store`. A recognized legacy `default.store` is copied, validated, promoted, and then archived under `Backups/`; an unrelated or malformed legacy file is left untouched.
- Redacted JSONL diagnostics are retained for 14 days and capped at 50 MB.
- History and logs can be cleared separately from Settings.
- Provider credentials remain in provider-managed storage.
- Network access is limited to behavior performed by the official provider CLIs; Agents Deck has no server of its own.
- The app does not contact GitHub for update checks. GitHub is used only when a person visits the repository or downloads a release.

## Distribution security

Release DMGs are built on an ephemeral GitHub-hosted macOS 26 runner using only Apple command-line tools. Each release includes a SHA-256 checksum and a GitHub artifact attestation. The workflow rejects local user paths, credential markers, internal development material, unexpected bundle contents, non-system dynamic libraries, and unexpected code-signing entitlements before publishing.

Version 1.3.1, like every release since, is ad-hoc signed because the project has no paid Apple Developer membership. Version 1.0.0 was withdrawn and replaced by 1.0.1 after release-build hardening. A checksum and attestation help verify the published artifact, but they are not substitutes for Developer ID signing and Apple notarization. The release page and this README intentionally disclose that limitation.

## Runtime design

- One SwiftUI menu bar application; no Dock icon.
- One cancellable coordinator scheduler with independently jittered Claude, Codex, and Antigravity rate-limit deadlines, a 15-minute Codex token-activity fallback, Claude local-stats freshness evaluation, and maintenance.
- One event-driven Claude bridge-directory observer.
- One Codex app-server process, terminated when Agents Deck quits.
- No helper daemon, launch agent, telemetry service, or permanently running tests.
- Launch at Login is optional and off by default.

The provider marks bundled in the UI are sourced from the official [Anthropic press kit](https://www.anthropic.com/press-kit) and [OpenAI brand guidelines](https://openai.com/brand/). Their inclusion does not imply affiliation or endorsement.

## Troubleshooting

**Xcode says Command Line Tools are active**

Install full Xcode, open it once to finish setup, then select it in **Xcode → Settings → Locations → Command Line Tools**. The usual terminal equivalent is:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

**A CLI is not found**

GUI apps do not always inherit your shell `PATH`. Open Agents Deck Settings and choose the exact `claude`, `codex`, or `agy` executable.

**Claude says Waiting for data**

Use Refresh and confirm `claude /usage` works in Terminal. Installing the optional bridge adds immediate post-response updates and session cost. Automatic refresh never runs faster than the selected range's one-minute minimum.

**Codex retry is paused**

Agents Deck stops automatic restarts after five failures in ten minutes. Confirm the CLI works, then use **Retry** or reconnect it from Settings.

**Where are diagnostics?**

Use **Settings → Diagnostics → Reveal Logs**. Logs contain event categories and error codes, not raw CLI output.

## License

[MIT](LICENSE)
