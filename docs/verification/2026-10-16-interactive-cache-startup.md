# Interactive cached startup / room Debug delivery

Status: implementation in progress, no candidate APK built or installed yet.

## Scope and identity

User approved the concrete design and requested implementation plus emulator Debug installation. Source baseline74cf7217, isolated branch `codex/interactive-cache-startup-20261016`, worktree `C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat`. Planned Debug0.4.49+2218. No public distribution authorized or performed.

Preflight at2026-10-16T20:59:43+08:00: emulator-5556 online/x86_64, packagecom.liuhetong.mobile.debug version0.4.47/2216, UID10090, firstInstall2026-09-26 04:06:20. Preserve install-r, never uninstall/clear. Flutter3.44.9/Dart3.12.2. Lock SHAa43833c8e7c3d6faa93d21babdc61dfe4b3563c7ac00912006f26daa8e0ecc5d. Fixed75b31 signer files present; no secret output. `.env` absent, complete verify.ps1 environment not satisfied.

## Evidence ledger

All relative paths below under `artifacts/2026-10-16/interactive-cache-startup/`.

| Area | Evidence | Result |
|---|---|---|
| Version identity | version-contract.log | 3PASS |
| HTML behavior | html-red.log → html-green-final.log | 4PASS/2expectedFAIL →6PASS |
| Registry/tokens | ui-contract.log | 34components/540screens PASS |
| HTML full | frontend-full.log | 563PASS/6FAIL, not all green |
| Unchanged download failures | frontend-baseline-targeted.log, baseline exact74cf7217 frontend | same6FAIL/5PASS in download-redirect,download-published-2196,orbit-production; old2213/signing-warning assertions |
| Room TDD | task1/*red*.log,environment.json | held room head/durable queue/no-journal/optional hydration failures observed |
| Room regression | task1/focused-green-final.log | 113PASS before final optional-dispatch decoupling |
| Room final narrow | task1/final-narrow-green.log | 5PASS on final44f079ba |
| Room analysis | task1/analyze.log | no issues |

SQLCipher fixture is a real FFI driver using an in-memory database, 80 persisted SDK events and held genuine Room.postLoad. It proves bounded head40/local-ready/retirement and missing-encryption refusal, not file encryption-at-rest or physical phone performance.

Baseline `am start -W -S` reports StatusOK/TotalTime8222ms; this Android activity metric is not app content readiness or a release performance claim.

## HTML review

Demo paths `frontend/index.html?screen=chat-experience-cached-start` and `?screen=chat-experience-recent-history`; local review URLport4189. Browser confirmed contacts→messages→open room→back while loading; pending→failure→retry→ACK retains same bubble. Row layout corrected after screenshot inspection. Screenshot connector refused filesystem saves for both primary and worktree; inline screenshot inspected instead. No Figma changes.

## Known boundaries and pending work

- Necessary installation/key/identity preflight remains; no account data before validation.
- Task1 local queue covers text. Existing media path remains subject to normal permission/storage readiness; do not claim a new early media queue.
- Task2 local navigation/home readiness integration and independent reviews pending.
- Shared final gates, final build/signature/rebuild/installation and passive runtime checks pending.
- User will perform manual functional testing; no human recipient messages sent by this task.

Exact total duration not yet available. Tool timestamps are recorded in preflight/progress; no invented active-vs-wait timing.
