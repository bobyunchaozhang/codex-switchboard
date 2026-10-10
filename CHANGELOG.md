# Changelog

## 0.4.4 — 2026-10-10

- Package separate arm64 and x86_64 DMG installers with SHA-256 checksums.
- Build and validate the requested architecture explicitly.
- Add automatic GitHub Release publication on version tags, gated by native checks and successful packaging of both architectures.
- Keep the macOS 14 minimum; real Intel account switching still needs manual acceptance.

## 0.4.3 — 2026-10-10

- Use five remaining-quota levels: green above 75%, cyan above 50%, yellow above 25%, orange above 10%, and red at 10% or below.
- Share one palette between account card tints, borders, and quota progress bars; cards reflect the lowest remaining quota window.
- Document the approved thresholds, including yellow at 39% remaining.

## 0.4.2 — 2026-10-07

- Show recovery only for unfinished operations after active work has stopped.
- Preserve the verified Current badge during quota reads and switch preflight.
- Hide premature identity messages during active work and check actual list membership before reporting an unregistered account.
- Cover transient controller journals and menu status timing in regression checks.

## 0.4.1 — 2026-10-07

- Fix false switch blockers caused by Chrome plugins and other helper processes inheriting the main Codex home.
- Recognize credential-owning desktop and CLI executables instead of matching Codex anywhere in a process path.
- Keep real CLI and unreadable live-owner protections; report blocking process IDs on timeout.
- Add classifier coverage and real disposable-process regression checks without restarting the user's Codex.

## 0.4.0 — 2026-10-07

- Promote the user-accepted fixed-home workflow into the existing menu bar app.
- Keep projects, all local chats, and MCP configuration in one work home; switch only login caches.
- Store inactive caches in a dedicated Keychain service and retain official login and refresh behavior.
- Add one-time legacy migration with private recovery records and additive standalone-chat import.
- Preserve current-account removal protection, official logout, usage caching, and existing menu styling.
- Support active-account re-login and recover interrupted switches or removals without regressing refreshed caches.
- Remove the separate preview app target and build script after integration.

## 0.4.0-preview.1 — 2026-10-06

- Add a separate fixed-home validation app; keep the installed 0.3.3 production app unchanged.
- Use official sign-in and usage requests with preview-owned credentials only; store inactive caches in a dedicated macOS Keychain service.
- Serialize usage reads and switching, preserve refreshed credentials, and verify the selected identity.
- Journal interrupted operations, restore the previous environment on failed switches, and provide explicit recovery and return actions.
- Add synthetic lifecycle, file-permission, and failure checks plus an installed-CLI/Keychain integration check.
- On October 6, 2026, the user confirmed the delivered manual acceptance flow met expectations, validating the core fixed-home account-switching workflow.
- Optional MCP authorization, natural OAuth token refresh, and prolonged sleep scenarios were not individually confirmed.

## 0.3.3 — 2026-10-06

- Fix the remaining switch failure in upgraded homes containing legacy truncated rollout aliases.
- Move an alias to a private backup only after verifying it matches the preserved continuation exactly.
- Repair only the matching stale rollout-path index in an offline transaction, retaining the previous value and verifying with official resume.
- Extend the full sharing regression to include legacy aliases; clean-home tests alone missed this state in 0.3.2.

## 0.3.2 — 2026-10-06

- Fix account-switch rollback caused by paginated project chats whose earlier history was not shared.
- Preserve continuation filenames, copy referenced base histories without editing them, and resume by explicit path.
- Repair imports from older versions on the next switch; stop on missing or conflicting histories.
- Add safe RPC method/error-code diagnostics and keep rejected-request errors visible.
- Cover history dependency discovery, missing/conflicting bases, and isolated installed-CLI recovery.

## 0.3.1 — 2026-10-01

- Clear stale transient action errors after a later successful panel-open or manual refresh.
- Identify the failed operation in error banners and retain unresolved storage, sharing, and compatibility errors.
- Log sanitized operation/error categories for diagnosis, without account details or credentials.
- Add focused notice-recovery checks; the original intermittent failure has not been reproduced.

## 0.3.0 — 2026-09-30

- Share custom MCP definitions and local project registrations across accounts.
- Update both backend registrations and the desktop sidebar, preserving local project IDs.
- Continue the same local-project chats across accounts with shared history and refreshed indexes.
- Keep standalone chats and account authentication independent; retain archived chat status.
- Back up original settings and chat files; block conflicting history copies instead of overwriting them.
- Support new-account inheritance and existing rollout filenames with extra UUID suffixes.
- Add regression coverage for configuration changes, sidebar registration, round-trip chat continuation,
  archives, independent chats, and conflict protection.
- User acceptance passed for switching to another account, continuing a project chat, switching back,
  and continuing with the new messages intact.

### Development milestones

- **0.2.0:** Shared MCP definitions and backend project registrations.
- **0.2.1:** Fixed missing desktop sidebar registrations.

## 0.1.0 — 2026-09-29

- Initial macOS menu bar app with multiple accounts, usage windows, reset-credit details,
  official sign-in, manual switching, and protected account removal.
