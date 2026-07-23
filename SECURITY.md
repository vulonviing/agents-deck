# Security Policy

## Supported versions

Security fixes are provided only for the latest `1.x` release, currently `1.2.0`. Version `1.0.0` was withdrawn and replaced by `1.0.1` after release-build hardening.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository. Do not open a public issue containing credentials, provider payloads, local paths, prompts, responses, source code, session identifiers, or diagnostic logs.

Include the smallest reproducible description possible. Replace account identifiers, paths, balances, timestamps, and provider content with synthetic values.

## Distribution trust

The free DMG is ad-hoc signed and is not Apple-notarized. Verify both the SHA-256 checksum and GitHub artifact attestation published with the release:

```sh
shasum -a 256 -c Agents-Deck-1.2.0.sha256
gh attestation verify Agents-Deck-1.2.0.dmg --repo vulonviing/agents-deck
```

Then follow the per-app **Open Anyway** flow described in the README. Never disable Gatekeeper globally to install Agents Deck.

Release automation rejects debug entitlements such as `get-task-allow`, unexpected app-bundle helpers or frameworks, non-system dynamic libraries, embedded local paths, credential markers, and internal development files. Release commits and annotated tags are SSH-signed and the repository uses protected branch and tag rules.

Agents Deck has no backend, telemetry, advertising, crash reporting, or automatic updater. Provider network activity is performed by the locally installed official Claude and Codex CLIs.

The app is intentionally not App Sandbox-enabled because it launches user-selected provider CLIs and, with explicit consent, safely merges the Claude status-line bridge into user-owned settings. It does not read provider credential stores, Keychain entries, prompts, responses, source code, or transcripts.
