# 2136 immediate failed message to one legacy friendship

## Authorization / source

User supplied the exact sender/recipient pair and failure interval after Android2136 release; prior explicit authorization covers direct production repair and ADR decisions. User wrote 2025-09-19 20:30–20:36; actual release and server clock are 2026-09-19. Investigation uses 2026-09-19T12:30Z–12:37Z and records that year assumption. No message contents, attachments, keys, synthetic user sessions or financial data read.

Source: a9034b73 (mobile candidate96637621), clean worktree .worktrees/conversation-reliability, branch codex/retired-direct-room-repair-20260919. Root dirty main retains other task modifications. [Plan](../../superpowers/plans/2026-09-19-retired-direct-room-repair.md), [ADR amendment](../../adr/2026-09-19-recoverable-direct-room-alias.md).

## Confirmed evidence

Both accounts ACTIVE, one friendship, zero block records. Exactly one canonical points to a room whose admin detail/state return200 but joined count0/stateempty. Independent Synapse local_current_membership proves both participants leave (recorded before this release). Exactly one common joined room exists; it is a registered history source with both expected users JOIN, no extra active members, Megolm, and send power allowed. Both m.direct arrays include old/new physical rooms. Incident-window encrypted event count for this pair in both rooms is0. Private identifiers/evidence remain host0700 at /opt/starchat/releases/direct-send-2136-20260919.

Root cause: blanket immutability of physical canonical had no operations correction for an exited room. Android2136 fresh-canonical send guard rejects the existing healthy source; the exited primary cannot accept a send. It is not evidence that iOS2134 protocol cannot receive2136 messages. Generic red bubbles still have multiple causes; this pair has independent server evidence.

## Work and ownership

Root owns plan/ADR/task/evidence/review. Implementation agent owns recovery service, strict metadata gateway and new regression tests. Production agent owns metadata/release scripts and execution after review. Client-review agent verified current2136 fallback: both directory endpoints must reflect newcanonical, preserve old source, reopen after sync, new unbound messages bind newtarget; old bound failed/uncertain messages never retarget.

Status at21:18+08: server deployed and selected-pair correction verified; device success now confirmed by user. Source c7534a33, main integration based on dc48cb95; source hashes unchanged from candidate. Candidate repair only explicitly selected pair, not all exited rooms. Existing Android/iOS binaries and update settings stay unchanged. [Evidence](../../verification/2026-09-19-retired-direct-room-repair.md), [operations runbook](../../runbooks/retired-direct-room-repair.md).

## Acceptance

- [x] Identify stale canonical from exact pair metadata and authoritative leave records.
- [x] Operations-only public service CAS, checked source/join/encryption/relationship/old-room retirement, actual-operator audit/idempotency/outbox; no HTTP/schema change.
- [x] Tests red/green, spec review then quality/security; applicable repository gates. Latest-main unrelated baseline failure remains separately recorded.
- [x] Isolated PostgreSQL correction/replay and rollback-source backup.
- [x] API overlay, selected-pair public-service correction, both directory readbacks, old room/source preserved, replay0newwrites.
- [x] Device confirmation: user explicitly reported normal sending after the repair. This confirms the incident pair, not all friendships.

## Timing and next step

First current-clock capture20:37:36+08. Pair read-only investigation and independent membership confirmation20:38–20:43 approximately; precise artifact timestamps supersede estimates. No invented total tool time. Implementation, review and bounded API repair are complete; fresh-message retest instructions were provided. Do not claim handset success without feedback.

By20:58+08,51 dedicated regressions and30 neighboring tests passed (35.67s), independent specification then quality/security reviews passed after three corrections. Candidate and isolated PostgreSQL preparation also passed. Full gate ran on Windows with Python3.12.10, basea9034b73 plus the frozen repair; requirements.lock SHA256029a0a13294bc678fe9e8f93b85ad74c0c78aa775f0bae4f1802503e29d9350e. Source hashes and exact image are in the evidence page. Main advanced concurrently to dc48cb95; independent integration tests were completed and base full-gate results must not be represented as a full run on that newer main.

Full gate20:53–21:14+08 completed exit0 (API/Worker2146 passed,58 skipped,1222.91s); separate latest-main friendship integration102 passed. The unrelated redpacket default assertion fails on pure main too and is recorded, not hidden. Deployment21:15:12, correction/replay21:15–21:16, independent readback21:16:48, dual-side TLS validation finished21:17:22; all timestamps+08. No ongoing command or owned tunnel remains. Next executable step is user fresh-text device verification after reentering the synchronized conversation; do not retry/retarget old uncertain bubbles as acceptance.
