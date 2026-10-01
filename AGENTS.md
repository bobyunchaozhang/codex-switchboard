# Codex Switchboard

Read PRODUCT.md and STATUS.md before changing behavior. Keep implementation,
comments, and UI text in English. Product discussion documents may use Chinese.

This is a fresh implementation. BobToolbox is a visual and historical reference;
do not copy its code or expand the approved feature set.

Use official Codex App Server requests for identity, usage, login, and logout.
Never read, copy, or log Codex authentication secrets or OAuth credential stores.
User-configured MCP definitions can include API keys; keep shared definitions and
configuration backups private (0700 directories, 0600 files), never print them.
Share custom MCP definitions and project registrations through the approved
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
