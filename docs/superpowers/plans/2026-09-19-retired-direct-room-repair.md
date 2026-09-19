# Retired direct-room destination repair

User has explicitly authorized production repairs and necessary ADR decisions in this conversation. This bounded incident continues that authorization. Product goal and privacy boundaries remain unchanged.

Goal: restore one existing friendship whose immutable canonical points to an exited room while both participants already share an encrypted registered source room. No new room, invitation, forced join, key/message access, outbox retargeting or financial change.

Architecture: ordinary client claim/register/publish/recover remains immutable. Add an operations-only public friendship service correction method (no HTTP route). Under existing pair lock, require expected-old compare-and-set, active friendship/no blocks, existing associated target, fresh exact-two JOIN+Megolm evidence, and strictly typed existing old-room admin details showing joined_members=0 plus no active invite/join/knock or ban in old state. A 404, unknown/malformed metadata or active old room refuses correction. Explicit operational selection is necessary, not timeout or auto-election. Preserve old canonical as historical source; write operator-attributed before/after audit + transactional outbox and stable idempotency. Replay must add no audit/outbox/history and never flip back. Reservations remain fenced.

Files owned: implementation agent direct_room_recovery.py / matrix_admin.py / dedicated friendship and gateway tests; root ADR/runbook/task/evidence; production agent metadata and release scripts only. Clean source worktree .worktrees/conversation-reliability branch codex/retired-direct-room-repair-20260919 baseline a9034b73; root dirty tree preserved.

- [x] Confirm exact pair current membership and bounded incident log metadata (read-only, private IDs stay host).
- [x] Add failing tests for expected correction, active/malformed old evidence rejection, target membership/source/friendship/block rejection, CAS conflict, replay and concurrent correction.
- [x] Implement minimal public service and strict read-only gateway detail method; no API or schema change.
- [x] Specification review then independent quality/security review; preserve immutability for all ordinary client APIs.
- [ ] Focused tests, applicable verify.ps1 with environment preflight/evidence accounting; isolated PG correction/replay rehearsal.
- [ ] Build exact overlay atop freshly checked live image; protect source/config/database rollback evidence; deploy only API.
- [ ] Invoke public service for this user-authorized pair with fresh evidence; read back canonical/source/audit/idempotency and preserve all physical rooms.
- [ ] Explain fresh-message retest vs existing ambiguous failed rows; do not claim device acceptance from metadata.
