# Automatic direct-conversation recovery implementation plan

Goal: remove permanent stale-room failures for valid friendships without losing history or duplicating uncertain sends.

Approved scope and authorization: [specification](../specs/2026-09-19-direct-conversation-auto-recovery.md). Stack: Python/SQLAlchemy/PostgreSQL, Matrix metadata, Flutter/Dart persistent outbox. Worktree conversation-reliability, branch codex/direct-conversation-auto-recovery-20260919, base2080b480; unrelated root edits preserved.

- [x] Audit current server metadata and actual old-client send/open paths; record confirmed incident device success.
- [x] Server owner: new lifecycle module, recovery model/additive migration, service/API integration, strict metadata helpers, dedicated red/green tests and generated OpenAPI. Final focused53 passed; production/full-gate acceptance remains below.
- [x] Client owner: coordinator API contracts, resolver/generation transport, new-operation preparation and stale-page reconciliation, scoped regression tests. Flutter3604 passed/analyze clean; mobile source frozen6aca8636, release not yet published.
- [ ] Root: ADR, specification compliance and independent quality/security review, task/evidence/current-state; resolve cross-component contract and any review failures.
- [ ] Freeze input hashes; focused then appropriate full gates; isolated PostgreSQL expansion/restore/concurrent resolve/publish and idempotence. Reuse unchanged build evidence only for unchanged inputs.
- [ ] Server operator: fresh live baseline and protected backups; exact overlay/additive migration, eligible metadata recovery, both directory readbacks, health/auth/TLS/other-container verification. No direct table patching or forced joins.
- [ ] Mobile build/release under existing authorization after version/signing/CI preflight, Android fixed-signer workflow; iOS candidate for user re-signing. Merge reviewed changes into current main preserving concurrent work, push GitHub, document exact shipping boundaries and remaining user-dependent steps.
