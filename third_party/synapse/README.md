# Synapse 1.132.0 ChatFlow media patch

Implements ADR-0060: standard uploads of identical received bytes share one MXC,
while each uploader has an independent logical reference. It does not inspect
encrypted room events or receive their plaintext hashes. Ordinary avatars are
still ordinary media; this patch does not encrypt them.

## Provenance and build

Base image is pinned in Dockerfile by tag and registry manifest digest. The digest
was fetched from Docker Registry's authenticated public manifest endpoint; evidence
is under docs/verification/artifacts/2026-09-09/media-dedup-implementation/.
Pristine Python source came from the PyPI matrix-synapse 1.132.0 source distribution.
`upstream-manifest.json` pins all five changed source files and exact patched
results. `apply_patch.py` rejects any source drift, validates every file before
writing, and installs the helper plus additive schema delta 92/99. The reviewable
patch is in patches/0001-cross-user-media-dedup.patch.

Build from the repository with `docker compose --env-file .env.example build synapse`.
When upgrading an existing environment, set SYNAPSE_IMAGE to
`starchat/synapse:v1.132.0-dedup.1` in its protected configuration; do not tag the
patched build as the upstream matrixdotorg image. Main and workers use the same
image. No deployment is performed by this task.

To regenerate after an intentional source review, invoke `regenerate_patch.py`
with an extracted pristine upstream root, then test strict application again.
Generated upstream derivatives preserve the upstream AGPL notices; this helper
and SQL are part of the same Synapse modification. Source bundle must remain
available with distribution of the patched server under the upstream license.

## Lifecycle and limits

- A global Synapse database-backed worker lock serializes publication, logical
  deletion, physical collection and admin quarantine. Hashing runs before it.
  A per-HomeServer Linearizer queues local waiters before this database lock, avoiding local exponential retry contention without removing cross-process exclusion. This favors correctness over maximum media-write throughput; measure before
  sharding it. Unique SQL digest and reference constraints remain the backstop.
- References are (media_id,user_id), not messages. Repeated uploads refresh an
  existing reference. The server cannot count encrypted-event references.
- Per-user media listing/statistics use a view of live references plus unindexed
  legacy media. Accounting is logical uploaded bytes per user, not disk usage.
- Per-user delete drops only that user's reference. Global ID deletion revokes
  all live references for that ID. Shared blobs are retained for the configured
  grace period; repeated logical deletion does not restart the grace clock.
- Purge/retention rechecks live references under the same lock. Quarantined shared
  blobs are retained as digest-denial evidence until explicitly unquarantined.
  This is deliberate: collecting their last hash row would allow reupload.
- Physical collection is reached through Synapse's existing retention/admin
  date-size purge; it is not scheduled merely by setting the grace duration.
  Active uploader references are not silently expired by the old file age policy.
- Existing files are not reindexed at install. Publication records a pending ID
  before writing bytes, then atomically publishes references and clears the intent.
  Failed cleanup retains the intent, hides the unpublished upload in user views,
  and must finish recovery before another same-digest upload can start. Collection
  persists a retiring marker before unlink; later upload/purge completes recovery.
  A missing active canonical backing file
  returns 503 and requires restoring storage, rather than returning a broken ID.
- The two-step pre-reserved-ID upload API retains the ID it already issued; its
  completion checks the same digest quarantine boundary but does not deduplicate
  IDs. The Flutter standard upload path is covered. URL-preview/remote caches
  retain upstream semantics; URL previews remain disabled by configuration.
- Canonical download filename/MIME are from the original blob; each uploader's
  listing preserves its metadata. Encrypted chat display uses event metadata.

## Rollback

Set CHATFLOW_MEDIA_DEDUP=false to stop merging new standard uploads, but retain
the patched image so existing reference listing/deletion/collection stay correct.
Existing shared files and new/old Matrix v2 events remain readable. Do not revert
to an upstream image for cleanup while shared references exist. The schema is
additive; dropping it or using an old cleanup tool is not a supported rollback.

Store and adapter tests use real SQLite transactions and files with framework
types mocked. They do not substitute for the isolated PostgreSQL/Synapse/Redis
container tests and load scenario described in the capacity runbook.
