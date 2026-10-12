# Codex Switchboard

Read PRODUCT.md and STATUS.md before changing behavior. Keep implementation
and comments in English. UI supports English (default) and Simplified Chinese,
as authorized on 2026-10-12. Product discussion documents may use Chinese.

This is a fresh implementation. BobToolbox is a visual and historical reference;
do not copy its code or expand the approved feature set.

Use official Codex App Server requests for identity, usage, login, and logout.
Never read, copy, or log Codex authentication secrets or OAuth credential stores.
Exception approved on 2026-10-06 after successful preview acceptance: production
0.4 may manage opaque account login caches in its own Keychain service and the
single fixed work Home. The user authorized the production replacement, one-time
migration, and temporary-file cleanup. Migration may import existing accounts'
caches without printing, decoding tokens, or committing secrets. Keep recovery
data private. Adopt the existing primary Home; import missing local chats through
official resume APIs, never merge entire databases. All local chats are shared.
Remove preview/build/test artifacts only after verification; preserve actual
account homes, chat data, and necessary recovery backups. Real desktop switches
remain user-triggered; automated checks use disposable fixtures.
User-configured MCP definitions can include API keys; keep shared definitions and
configuration backups private (0700 directories, 0600 files), never print them.
The following describes the legacy 0.3 migration helpers only; never call them
as part of routine 0.4 account switching. Share custom MCP definitions and project registrations through the approved
shared registry and App Server APIs. The sidebar also requires a narrow update of
project fields in .codex-global-state.json while the desktop is stopped. Preserve
unrelated fields, existing local project IDs, and chat associations; back up only
project fields. Never treat project/list success as sidebar verification.
Keep desktop-managed runtime MCP settings
local. The user now authorizes sharing local-project chats: share their individual
rollout files and use official resume/metadata APIs for per-home indexes. Preserve
projectless chats, authentication, existing homes, and separate SQLite databases.
Never merge or redirect entire chat databases. Back up original rollout contents
before linking; conflicting copies must stop the switch, never overwrite history.
Legacy truncated rollout aliases also require a narrowly scoped offline repair of
threads.rollout_path. Back up the old path, require the expected thread and alias,
compare file contents, and use a transaction. Do not modify any other database
fields; resume through the official API afterward.

Build with `swift build --product CodexSwitchboard`; run focused checks with
`swift run SwitchboardChecks` (no Xcode test framework required). Package with
`./scripts/build-app.sh`. Do not quit the hosting Codex desktop application or
log out a real account during automated validation; these terminate the user's
session. Prepare the app first and record remaining manual acceptance steps.

For every version update, update the release documentation, commit the verified
changes, and push the commit and matching version tag to the configured GitHub
remote. The user has authorized this recurring release step; do not leave a
version update only on the local machine. Verify the remote commit and report
any upload failure without claiming the release was uploaded.

For every release, publish separate arm64 and x86_64 DMG installers with SHA-256
checksums to GitHub Releases. Build them with `./scripts/package-release.sh`;
version tags trigger `.github/workflows/release.yml`. Verify both remote assets
before claiming installer publication. Keep Intel manual acceptance distinct
from cross-compilation and native fixture checks.
