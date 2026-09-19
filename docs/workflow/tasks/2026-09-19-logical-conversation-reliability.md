# Logical conversation reliability repair

## Authorization and ownership

User explicitly authorized implementation, necessary ADR decisions and production repair on 2026-09-19. [Approved plan](../../superpowers/plans/2026-09-19-logical-conversation-reliability.md), [ADR](../../adr/2026-09-19-recoverable-direct-room-alias.md).

Baseline 8051edb5; branch codex/conversation-reliability-20260919; worktree D:/pythonProject/outsource/StarChat/.worktrees/conversation-reliability. Root checkout contains unrelated ongoing changes and is preserved. Server agent owns recovery/API/migration; timeline agent owns merged timeline/registry/navigation; outbox agent owns SDK/send/controller; root owns integration and final acceptance. No overlapping concurrent edits.

## Status

Server deployed and metadata repair completed 2026-09-19 19:37 +08. Client implementation and independent specification/quality review complete; composite automated gates passed (see exact command accounting). No APK built or installed in this task.

| ID | Acceptance | Evidence / state | Remaining boundary |
| --- | --- | --- | --- |
| C1 | One logical conversation across entries | Identity projection, durable associations, dm:peer navigation, pending-page reuse | New client must be delivered |
| C2 | Preserve history and source anchors | Same-page merged timelines, source pagination/media/reply/receipt routing | Non-joined/inaccessible sources cannot promise immediate loading |
| C3 | Correct send target | Durable unbound text, canonical binding, fresh account/relationship/encryption/exact-member checks | Unknown authority defers sends; no availability guarantee |
| C4 | Offline failed feedback and restart | Stable text outbox IDs, waitingNetwork/failed red bubbles, account-level recovery | Media kill-process recovery is not implemented |
| C5 | No replay into a different room | Existing room+transaction ID retained; foreign rows cannot resend via canonical | Old ambiguous/failed source rows are preserved without automatic retarget |
| S1 | Recover lost claim/create/publish response | Fixed reservation alias, verified recovery, immutable canonical | Physical duplicate rooms remain possible and are retained |
| S2 | Production recovery | 11 pending repaired, pending 0, 65 canonicals, original 54 unchanged, 22 sources | Five exited canonicals intentionally unchanged |
| S3 | Idempotency and privacy | 22-operation replay: zero domain/audit/Outbox changes; metadata-only service operations | Raw metadata and operator audit remain protected on host |

## Version and evidence

Server image sha256:1539d35f4584e1b350fa9246dcf5c9214845e490e371438d4b3178a1ae39ecd4; schema 0070_direct_room_history. Built on actual production 026f6dbc image, preserving already-deployed BUG-21/BUG-11 fixes absent from this baseline. [Server evidence](../../verification/2026-09-19-direct-room-v2-server.md), [production result](../../verification/artifacts/2026-09-19/conversation-reliability/PRODUCTION-RESULT.md).

Client toolchain: Windows, Flutter 3.44.9 / Dart 3.12.2. Backend: Python 3.12. Exact final source identity and test accounting: [client evidence](../../verification/2026-09-19-logical-conversation-client.md). No device OS/build result is inferred from unit tests.

## Stage timings

Earlier implementation start was not captured; no invented overall duration. Full backend gate took 1207.61s; first two full Flutter runs took approximately 2:11 and 2:13 respectively. Rework corrected test fixtures, immediate visible receipts and Windows non-normalized long-path fixture. Migration: 19:31:06.772–19:31:10.587 +08; healthy API 19:31:24.130; repair/replay complete 19:37:02. Parallel review and test timings overlap and must not be summed as total wall time.

## Handoff and rollback

Protected backup and exact rollback commands are in /opt/starchat/releases/conversation-reliability-20260919 (0700); application rollback preserves additive schema/source/audit data. No room deletion, forced joins, key resets, financial mutation or message plaintext inspection occurred. Task-owned network-none rehearsal containers were stopped after verification; volumes/backup remain. Local verification tunnel closed.

Next executable step: commit this verified isolated branch, then integrate with the separately modified root branch without overwriting its work; build/sign/deliver through the approved mobile workflow and run actual two-device/offline/restart acceptance. Source completion and server deployment do not imply an installed client release.
