# Changelog

## 1.4.0 (unreleased)

- Parse ChatGPT main limits by explicit endpoint paths and keep additional limits separate with stable IDs.
- Preserve the last official reading on failure, record the latest attempt and error, and mark it historical.
- Store uncapped spending as numeric currency amounts; exclude amounts from quota selection, percentage graphics and alerts.
- Select the headline deterministically from the minimum remaining quota plus a five-point tolerance.
- Prefer Cursor's structured budget fields to conflicting dashboard prose and show a conflict note.
- Add independent provider switches, explicit paused states, first-use consent and login help.
- Keep appearance and interval changes separate from usage requests, and track battery requirements in graphic slots.
- Publish each provider independently; stop Cursor fallback on cancellation or rate limits, remember successful endpoints, recognize disabled on-demand usage and bound a refresh to 25 seconds.
- Honor Retry-After and exponential backoff for rate limits.
- Use log-event timestamps, explicit account matching and a 24-hour maximum age; search up to 20 recent files, cache the directory index and read appended data incrementally.
- Extract pure refresh scheduling rules, shared transport backoff, account state merging and diagnostics from the monitor.
- Add offline XCTest regression tests, universal builds, ad hoc signing with hardened runtime, verified DMG and ZIP packages, SHA-256 checksums and GitHub Actions.
- Add a whitelist-based diagnostic export, MIT license and contribution guidance.
- Add an on-demand check for the latest stable GitHub release and its download link in Settings. Updates remain manually installed.

## 1.3.2

- Notify once per quota cycle while low quota remains; suppress already-exhausted alerts.
- Refresh after the display wakes, including opening the laptop lid.
