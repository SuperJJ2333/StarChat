# Automatic direct-conversation recovery implementation plan

Goal: remove permanent stale-room failures for valid friendships without losing history or duplicating uncertain sends.

Approved scope and authorization: [specification](../specs/2026-09-19-direct-conversation-auto-recovery.md). Stack: Python/SQLAlchemy/PostgreSQL, Matrix metadata, Flutter/Dart persistent outbox. Worktree conversation-reliability, branch codex/direct-conversation-auto-recovery-20260919, base2080b480; unrelated root edits preserved.

- [x] Audit current server metadata and actual old-client send/open paths; record confirmed incident device success.
- [x] Server owner: new lifecycle module, recovery model/additive migration, service/API integration, strict metadata helpers, dedicated red/green tests and generated OpenAPI. Final focused53 passed; full gate and production acceptance completed.
- [x] Client owner: coordinator API contracts, resolver/generation transport, new-operation preparation and stale-page reconciliation, scoped regression tests. Flutter3604 passed/analyze clean; mobile source frozen6aca8636, Android published; iOS candidate verified for enterprise handoff.
- [x] Root: ADR, specification compliance and independent quality/security review, task/evidence/current-state; resolve cross-component contract and any review failures.
- [x] Freeze input hashes; focused then appropriate full gates; isolated PostgreSQL expansion/restore/concurrent resolve/publish and idempotence. Reuse unchanged build evidence only for unchanged inputs.
- [x] Server operator: fresh live baseline and protected backups; exact overlay/additive migration, eligible metadata recovery, both directory readbacks, health/auth/TLS/other-container verification. No direct table patching or forced joins.
- [x] Mobile build/release under existing authorization after version/signing/CI preflight, Android fixed-signer workflow; iOS candidate for user re-signing. Merge reviewed changes into current main preserving concurrent work, push GitHub, document exact shipping boundaries and remaining user-dependent steps.

Delivery boundary: API4996/0071 and Android0.3.98/2137 are live. iOS2137 candidate is built and verified; enterprise re-signing and physical-device feedback remain user-dependent. All three GitHub workflows passed against742bf4eb, including iOS18/26 native media and restart-history compatibility.
