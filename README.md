# Codex Switchboard

A macOS menu bar app for viewing Codex account usage and switching accounts while
sharing custom MCP configuration, local projects, and project chat history.

**Current version: 0.3.0.** Real two-account round-trip chat continuation was
accepted on September 30, 2026. See [CHANGELOG.md](CHANGELOG.md).

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

Custom MCP definitions and local project folders are shared automatically when
switching. Existing unique entries are combined. If accounts have different
versions of the same entry, one review screen lets you choose which to keep.
Later additions, edits, and removals propagate at the next switch. New accounts
inherit the setup and local-project chats on their first switch. A project chat
keeps its original identity and context across accounts. Standalone chats stay
independent. Archived project chats keep their archived status; permanent chat
deletion is not propagated. Cloud ChatGPT conversations are not migrated.

Desktop-managed runtime services (`node_repl`, `cua_repl`, and MCP definitions
containing `CODEX_HOME`) stay local. Plugin installations and account-bound cloud
connections are not included. Standard MCP OAuth uses the macOS Keychain; old
file-based OAuth credentials require a separate migration and block automatic
setup changes.

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
| `STATUS.md` | Current handoff and validation status |
| `CHANGELOG.md` | Version history |
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
credentials. Neither switches or signs out real accounts. `--check-sharing` performs a read-only
shared-setup preflight and reports counts only.

To test against an installed CLI using disposable homes and projects:

```sh
swift run SwitchboardChecks --integration-cli /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex
```

The preflight reports backend and desktop-sidebar project counts separately.
The sidebar registry is in each home's `.codex-global-state.json`. Switchboard
patches only its local project list, ordering, project-ID mapping, and relevant
pending-deletion records while Codex is stopped. Existing local project IDs and
chat associations remain intact; an invalid selected project is cleared.

Project-chat integration checks use a loopback model with synthetic replies;
no real login or paid model calls are involved:

```sh
swift build --product SwitchboardChecks
python3 Tests/Integration/chat_sharing.py
```

Project registration uses experimental App Server APIs verified with CLI
`0.158.0-alpha.2.1`; future Codex updates may require compatibility changes.

## Local data

Account labels and Codex-home paths live in
`~/Library/Application Support/Codex Switchboard/accounts.json` (mode 0600).
New sign-ins use individual directories under `Codex Switchboard/Accounts`;
existing accounts retain their original homes. Credentials are never copied.
These runtime directories are separate from the source project and build cache.

Shared setup lives at `~/Library/Application Support/Codex Switchboard/Shared/setup.json`.
It can contain secrets from custom MCP definitions: keep this directory private
and out of Git. Files use mode 0600 and directories use mode 0700.
Before changing a home's settings, Switchboard saves its original and previous
configuration, project descriptors, and affected desktop project fields under `Shared/Backups/<home hash>/`;
`home.txt` identifies the destination. It never changes `sqlite_home` or copies
chat databases. Project chat rollouts are hard-linked individually through
`Shared/Chats/Sessions`; this requires the homes and shared data on the same
filesystem. Original content is backed up once under `Shared/Chats/Backups`.
`Shared/Chats/chats.json` records the shared chat identities and participating
homes. Treat all these files as private conversation data and keep them out of Git.
At each switch, official resume requests refresh the destination's turn/item
indexes, followed by backend and desktop project assignments. No conversation
turns are submitted by Switchboard itself. Conflicting history copies stop a
switch instead of overwriting either version.

A failed setup prevents the destination launch and attempts to
reopen the previous account; partially applied setup is retried on the next switch.

To roll back chat sharing, quit Switchboard and Codex and detach each shared
rollout into an independent file before returning to an older app. Preserve its
current contents using a new temporary file followed by a rename; writing into
an existing hard link also changes every linked copy. Participating homes are
listed in `Shared/Chats/chats.json`. Keep the original chat backups until recovery
is verified. Removing Switchboard does not detach shared chat files automatically.

To roll back configuration sharing, quit Switchboard and Codex, restore the affected home's
`original-config.toml` as `config.toml`, and use the previous Switchboard app.
Use Codex's project controls to restore the registrations recorded in
`original-projects.json`. Desktop project fields are backed up separately in
`original-desktop-project-fields.json`; restore only those fields into the
current global state while Codex is stopped, never replace the entire state
with that partial backup. Do not replace any chat database. Keep the private
backup directory until the rollback is verified.

Identity and usage are read through the official Codex App Server in each
account's environment. Task activity cannot currently be determined reliably;
the app does not claim that running tasks are idle.

The thumbs-up artwork is by Streamline, licensed under CC BY 4.0. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
