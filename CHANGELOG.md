# Changelog

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
