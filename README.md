# Codex Switchboard

A macOS menu bar app for viewing Codex account usage and switching accounts.

## Open the app

Open **Applications → Codex Switchboard**, then click the **thumbs-up icon** in
the menu bar. The app has no Dock icon or main window. Clicking outside the panel
closes it; **Quit** stops the app. Double-click the application to start it again.

This machine's installed copy is `/Applications/Codex Switchboard.app`.
You can also search for **Codex Switchboard** in Spotlight (`Command-Space`).

## Use

- Opening the panel refreshes all accounts. Previous results stay visible while
  **Refreshing…** is shown; a failed read clears the affected quota values.
  The cache lasts for the current app session.
- Each card shows the email, plan, quota windows, remaining percentages, reset
  times, and reset credits. Expand the credits row for individual expiry dates.
- The gold **Current** badge identifies the confirmed active account.
- **Switch** closes and reopens Codex with the selected account. Running Codex
  work may be interrupted.
- **Add Account** and **Sign In** use the official browser sign-in flow.
- **… → Remove Account** signs out and removes a non-current account. Removal
  is disabled when the active identity is unknown. Project and chat files stay.

Register local projects once per account. Project files are shared on disk;
project registrations and chat history are not synchronized between accounts.

## Develop

Requires macOS 14 or later, Apple Swift command line tools, and an installed
Codex desktop app. No third-party Swift packages are required.

```sh
swift build --product CodexSwitchboard
swift run SwitchboardChecks
./scripts/build-app.sh
```

The last command creates `dist/Codex Switchboard.app`. To install an updated
build, quit Switchboard, then run:

```sh
ditto 'dist/Codex Switchboard.app' '/Applications/Codex Switchboard.app'
open '/Applications/Codex Switchboard.app'
```

Builds are ad hoc signed for local use, not notarized for public distribution.
`.build/` and `dist/` are generated, ignored by Git, and safe to regenerate.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/SwitchboardApp/` | Menu bar app, views, and view model |
| `Sources/SwitchboardCore/` | Account storage, official protocol, usage, switching |
| `Sources/ProcessEnvironment/` | Native process-environment reader |
| `Tests/` | Core checks with local fixtures |
| `Assets/` | Original thumbs-up SVG and packaged application icon |
| `scripts/` | App packaging |
| `PRODUCT.md` | Confirmed product requirements |
| `STATUS.md` | Phase-one handoff and validation status |
| `AGENTS.md` | Contributor instructions |
| `THIRD_PARTY_NOTICES.md` | Icon attribution and license |

To regenerate the Finder/application icon after editing the SVG, run
`swift scripts/generate-app-icon.swift` before packaging.

## Validation

The core checks use fixtures and temporary directories, without changing real
account authentication. The built executable also provides:

```sh
'dist/Codex Switchboard.app/Contents/MacOS/CodexSwitchboard' --check-layout
'dist/Codex Switchboard.app/Contents/MacOS/CodexSwitchboard' --check
```

`--check-layout` checks the actual hosted panel with sample data. `--check` reads
saved account identities and quota availability without printing emails or
credentials. Neither switches or signs out real accounts.

## Local data

Account labels and Codex-home paths live in
`~/Library/Application Support/Codex Switchboard/accounts.json` (mode 0600).
New sign-ins use individual directories under `Codex Switchboard/Accounts`;
existing accounts retain their original homes. Credentials are never copied.
These runtime directories are separate from the source project and build cache.

Identity and usage are read through the official Codex App Server in each
account's environment. Task activity cannot currently be determined reliably;
the app does not claim that running tasks are idle.

The thumbs-up artwork is by Streamline, licensed under CC BY 4.0. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
