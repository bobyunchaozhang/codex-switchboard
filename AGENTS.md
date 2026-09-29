# Codex Switchboard

Read PRODUCT.md and STATUS.md before changing behavior. Keep implementation,
comments, and UI text in English. Product discussion documents may use Chinese.

This is a fresh implementation. BobToolbox is a visual and historical reference;
do not copy its code or expand the approved feature set.

Use official Codex App Server requests for identity, usage, login, and logout.
Never read, copy, or log authentication secrets. Never synchronize project or
chat databases. Keep each account's existing Codex home intact.

Build with `swift build --product CodexSwitchboard`; run focused checks with
`swift run SwitchboardChecks` (no Xcode test framework required). Package with
`./scripts/build-app.sh`. Do not quit the hosting Codex desktop application or
log out a real account during automated validation; these terminate the user's
session. Prepare the app first and record remaining manual acceptance steps.
