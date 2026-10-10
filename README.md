# Codex Switchboard

A macOS menu bar app for checking Codex usage and switching accounts.
**Version: 0.4.3.** One fixed Codex home keeps local projects, chats, and MCP
configuration available across accounts. See [CHANGELOG.md](CHANGELOG.md).

## Open and use

Open **Applications → Codex Switchboard**, or search with Spotlight.
Click the **thumbs-up icon** in the menu bar. Clicking outside closes the panel.
After **Quit**, reopen `/Applications/Codex Switchboard.app`.

- Opening the panel refreshes all accounts. Cached results remain visible during
  loading; failed reads show **Unavailable**. Cache lasts for the app session.
- Cards show email, plan, quota windows, reset times, and reset credits.
  Expand the credits row to see individual expiry dates.
- Quota colors follow remaining usage: >75% green, >50–75% cyan,
  >25–50% yellow, >10–25% orange, and ≤10% red. Card tint uses the lowest
  remaining quota window.
- The gold **Current** badge marks the verified current account.
- **Switch** restarts Codex with the selected login. Running work can be interrupted.
- **Add Account** and **Sign In** use official browser login.
- **… → Remove Account** signs out a non-current account and removes its saved
  login. Current accounts cannot be removed; unknown identity disables removal.
- **Recover Interrupted Operation** appears only when recovery is needed.

All local chats, including standalone chats, share the fixed work home. Project
files stay in their existing folders. Cloud chats and account-bound services
remain subject to the signed-in account's permissions. Local MCP configuration
and authorization use the same paths across switches.

## Build and install

Requires macOS 14+, Swift command line tools, and the Codex desktop app.
No third-party Swift packages are needed.

```sh
swift build --product CodexSwitchboard
swift run SwitchboardChecks
swift run AccountRuntimeChecks
./scripts/build-app.sh
```

Quit Switchboard before replacing its application:

```sh
ditto 'dist/Codex Switchboard.app' '/Applications/Codex Switchboard.app'
open '/Applications/Codex Switchboard.app'
```

Builds are ad hoc signed for local use, not notarized for public distribution.
`.build/` and `dist/` are generated and can be removed after installation.

## Upgrade from 0.3.3

Quit Switchboard and Switchboard Preview. Keep the existing Codex desktop on its
primary `~/.codex` home. Before opening the new menu app, run its one-time migration:

```sh
'/Applications/Codex Switchboard.app/Contents/MacOS/CodexSwitchboard' --migrate
```

Migration adopts the primary home, imports saved account caches into the private
Keychain service, and imports missing standalone chats through official resume
requests. Existing project chats must already be present in the primary home;
unsupported ownership stops migration rather than guessing. Original account
homes and recovery backups remain. Routine switches do not call this importer.

## Local data and recovery

| Location | Purpose |
| --- | --- |
| `~/.codex` | Fixed work home on this installation; active login, projects, chats, MCP |
| `~/Library/Application Support/Codex Switchboard/Runtime/state.json` | Account labels, fixed-home path, operation journals |
| `Codex Switchboard/Runtime/Workers/` under Application Support | Temporary official login/usage environments; cleaned after completion |
| Keychain service `local.codex-switchboard.credentials.v1` | Opaque inactive login caches and recovery slots |
| `Codex Switchboard/Recovery/0.3.3/` under Application Support | Upgrade configuration snapshot, registry, migration receipt, previous app |

Runtime files are private and excluded from Git. Official Codex handles token
refresh. Switchboard saves the latest cache after reads and serializes operations.
It checks effective file-based credential storage and does not override managed
policy. Never print or commit authentication files, Keychain contents, MCP secrets,
or conversation data.

After a failed switch, Switchboard attempts to restore the previous login. If
interrupted, click **Recover Interrupted Operation** before continuing.
The old `accounts.json`, `Proof-B`, and `Shared` directories are retained for
recovery; they are no longer used for routine switching. Legacy shared rollouts
may still be hard-linked, so do not overwrite old files or restore whole databases.

For a version rollback, quit Switchboard, retain the entire current work home and
Runtime directory, and restore the saved 0.3.3 app from Recovery. Old inactive
caches may need official re-login after newer credentials were refreshed. The
backup is a recovery starting point, not an automatic complete rollback command.

## Validation

```sh
swift run AccountRuntimeChecks --integration-cli /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex
python3 Tests/Integration/chat_sharing.py --migration
'dist/Codex Switchboard.app/Contents/MacOS/CodexSwitchboard' --check-layout
```

Checks use disposable fixtures, a loopback model, and synthetic login data. They
do not switch or sign out real accounts. With Switchboard closed, `--verify-runtime`
reads real account identities and quota availability and prints counts only.
Real desktop switching remains user initiated. Compatibility was checked against
Codex CLI 0.160.1; future Codex changes may require updates.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/SwitchboardApp/` | Menu bar UI |
| `Sources/AccountRuntime/` | Fixed-home account lifecycle, Keychain, recovery |
| `Sources/SwitchboardCore/` | Official protocol, usage, desktop launch, migration helpers |
| `Sources/ProcessEnvironment/` | Native process-home detection |
| `Tests/` | Runtime, core, migration, and legacy regression fixtures |
| `Assets/` | Thumbs-up artwork and application icon |
| `scripts/` | Packaging and icon generation |
| `PRODUCT.md` / `STATUS.md` | Approved scope and current handoff |

The thumbs-up artwork is by Streamline, licensed under CC BY 4.0.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
