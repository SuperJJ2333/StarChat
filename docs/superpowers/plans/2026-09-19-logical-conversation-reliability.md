# Logical conversation reliability implementation plan

User authorization: 2026-09-19, execute the reviewed repair, decide the necessary ADR, and repair/deploy the production server. No repeated approval needed within this scope.

Goal: one visible conversation per friend, readable retained history, correct send routing, recoverable offline messages. A read-only duplicate room screen is not the final product.

Architecture: keep Matrix room/event/crypto identities intact. Maintain account-scoped conversation associations independently of the lossy m.direct projection. Navigate by the authoritative representative and retain source room/event anchors. Read all associated timelines inside the same page; send only through the confirmed primary. Unknown authority defers sending without blocking local navigation. Reconcile room creation outcomes instead of blindly expiring uncertain grants.

Baseline: 8051edb5. Isolated worktree `.worktrees/conversation-reliability`; root worktree contains unrelated ongoing changes and must not be overwritten.

## Task 1 — identity and timeline integration (root ownership)

- [x] Add red tests for canonical failure preserving m.direct, second-device association recovery, normalized primary navigation with source anchors, and merged timeline reads/receipts.
- [x] Persist association metadata in Matrix account data before any directory collapse; retain historical rooms, account isolation, and existing m.direct entries while authority is unavailable. Restore legacy local registry associations into durable metadata without losing other peers.
- [x] Normalize all direct-chat entries to one primary page. Preserve sourceRoomId with anchorEventId; primary timeline sends and related timelines only read. Merge messages deterministically by timestamp and source identity. Route receipts and source operations to the original room.
- [x] Keep the composer in the logical conversation; enforce read-only on every sending path if a standalone restricted lease is ever used.
- [x] Verify targeted Flutter tests and analyze, then review specification and security.

## Task 2 — server creation recovery (server subagent ownership)

- [x] Inspect claim/publish contracts and available Matrix reconciliation capabilities. Write failing response-loss and concurrency cases.
- [x] Author an ADR describing evidence-based recovery, backwards compatibility, stale creators, and rollback. Never reauthorize an ambiguous non-idempotent create merely because time elapsed.
- [x] Implement the compatible recovery contract and tests; preserve canonical publication and API authorization. No message plaintext or keys enter the business domain.
- [x] Update OpenAPI/runbook and provide exact production overlay/migration inventory. Root performs production deployment after review and isolated verification.

## Task 3 — pending/outbox recovery (root or separately assigned ownership)

- [x] Add red test for network recovery before an in-flight failure, page closed recovery, read-only outbox dispatch, and one black-holed room not blocking others.
- [x] Preserve stable outbox message identity and sender results across page transitions; do not replay raw text as a new message. Verify existing BUG-3 rather than reimplement it.
- [x] Apply bounded, coalesced recovery and account/permission guards. Never move an uncertain sent request to another room.

## Task 4 — gates, integration and deployment

- [x] Record baseline/tool versions/source identities and red-green evidence in the dedicated task record.
- [x] Run affected tests, full Flutter tests/analyze, business API/contract tests and applicable verify.ps1 after environment preflight.
- [x] Specification review precedes quality/security review. Resolve blockers before deploying.
- [x] Inspect current production image, schema and config via the approved jumper, preserve protected backup and rollback, deploy only reviewed server changes and validate health/authentication/contract/concurrency. Do not copy the dirty root tree.
- [x] Report client code, deployed server and device verification separately; no claim that an unbuilt client is already installed.

## Acceptance scenarios

room1 history + room2 recent test; canonical unavailable/unloaded; new device after convergence; old client sending to history room; list/search/notification/profile entering the same page; source anchor, history pagination and receipts; offline cold start; claim/create/publish response loss; late send success; pending handoff and restart; recovery while request in flight; account switch; media send state remains honest. No room deletion, key reset, plaintext upload or financial mutation is permitted as a repair technique.

## Completion scope

Implementation, reviewed ADR, composite automated gates and production repair are complete. Client packaging/device acceptance and integration with the separately modified root worktree are separate remaining delivery stages. Source rooms remain intact; text has durable recovery, media does not yet have kill-process recovery. See [client evidence](../../verification/2026-09-19-logical-conversation-client.md) and [task record](../../workflow/tasks/2026-09-19-logical-conversation-reliability.md).
