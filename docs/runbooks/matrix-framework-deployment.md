# Matrix framework deployment

This procedure applies to ADR-0060's Synapse 1.132.0 media patch and sync worker.
The user authorized production deployment on 2026-09-10, superseding the initial
local-only scope. Mobile binary publication remains a separate release.

## Prepare and review

1. Connect using `ssh -J jumper -p 23421 root@207.56.8.8`. Inspect the running
   image, Compose project labels, mounts, free resources and configuration drift.
   Keep `/opt/starchat` as the project directory and preserve Matrix server name,
   signing key, media paths, database identity, TURN and existing gateway routes.
2. Transfer an explicit allowlist to a new restricted release directory outside
   the live tree. Verify the archive and every source file with SHA-256. Never
   include local `.env`, databases, test accounts or credentials. Keep local
   verification artifacts under `docs/verification/artifacts/<date>/`.
3. Build `third_party/synapse/Dockerfile`, whose base is pinned by digest. Record
   the resulting image ID; main and worker must run that exact same image. Keep
   patch source and AGPL notices on the server for rebuild/source availability.
4. Back up live Compose, `.env`, templates, rendered configuration, signing keys,
   encrypted media and a custom-format Matrix `pg_dump` in a mode-0700 server
   directory. Restore the database into a disposable PostgreSQL 16.9 instance
   with no network/host ports and a resource limit. Check schema and media counts,
   then remove that disposable instance. Do not copy the private backup locally.
5. Verify the effective runtime configuration, not only the disk file. This
   release found a registration secret edited on disk after Synapse started.
   HMAC success with the known pre-edit configuration established the active
   value. Preserve that value in the candidate environment/configuration; do
   not rotate credentials as part of framework deployment. Keep the existing
   `push.include_content=false` setting. Record the correction without its value.
6. Run `scripts/prepare_matrix_release.py --root <private-live-copy> --source
   <verified-source> --image <explicit-release-tag> --output <new-candidate>`.
   It preserves unrelated Compose services and existing Nginx routes, validates
   immutable main settings and stages the seven changed config/template files.
   If an environment correction is staged separately, include it in the checked
   candidate manifest. Never print rendered secrets or full Compose config.
7. Validate merged production Compose and candidate Nginx in a temporary container
   on the existing network, with no published ports. Enforce loopback bindings for
   main and worker. Record live-file hash preconditions to reject concurrent drift.
   Complete focused tests, the shared verification script, domain review and then
   quality/security review before activation.

## Activate

Use service-specific Compose commands with the live project directory, environment
and root production overlay. Do not run an unqualified whole-stack `up -d`.

1. Record unrelated container IDs. Stop Synapse main, then take a final quiesced
   media/config snapshot and Matrix database dump. Validate the dump archive before
   replacing any live file. If backup fails, start the original main immediately.
2. Install the checked candidate files, deferring the rendered Nginx file. Write
   single-file mounts in place, preserving the inode and existing permissions.
   Make the worker config readable by the Synapse container user. Preserve live
   `.env` permissions; do not transfer secrets through command-line arguments.
3. Start/recreate only Matrix PostgreSQL (max_connections=250) and matrix-redis,
   wait for health, then start patched main. Let the normal Synapse migration
   runner apply `92/99_chatflow_media.sql`; never run destructive manual DDL.
4. Assert schema version 92 with `upgraded=true`, the applied delta, the three
   `chatflow_media_*` tables and `chatflow_media_user_view`. Start the sync worker
   only after main is healthy and this schema check passes.
5. Verify an existing opaque MXC and a pre-upgrade fixture still download with the
   same hash. Using dedicated test sessions, verify two users upload identical
   opaque bytes to one MXC and can read it; test authenticated main and worker
   `/sync`. Keep tokens, IDs and fixture bytes in restricted server storage.
6. Install the candidate Nginx file in place, run `docker exec
   starchat-gateway-1 nginx -t`, then reload. Verify authenticated public `/sync`,
   worker request evidence and both image IDs. Confirm unrelated container IDs
   are unchanged. Log out dedicated test sessions when verification finishes.
7. From both workstation and server check Matrix versions, business health,
   download page, TLS and unauthenticated access boundaries. Do not disclose logs
   containing tokens, account IDs or media paths. Publish only sanitized results.

## Rollback and limits

After the patched process has started, retain the patched image and additive
schema. Set `CHATFLOW_MEDIA_DEDUP=false` for main, recreate that service and verify
health. Restore the former Nginx route to main, test configuration and reload;
verify authenticated main/public sync and existing shared-media reads before
stopping the worker. Keep Redis while main configuration uses it. Restore the
corresponding template route as well, so later rendering does not undo rollback.
Never switch back to upstream media cleanup after shared references exist, and
never restore an old database over new production writes for a routine rollback.

Before any patched process starts, an installation failure may restore the old
configuration and restart the original main without restoring the database.
Restored configuration must still preserve the proven active authentication
values; do not recreate the original service against a known stale disk secret.

HTTP smoke tests do not prove real-device E2EE interoperability or capacity.
The [runtime report](../verification/2026-09-10-media-capacity-runtime.md) retains
500-VU first-burst failures: worker routing alone did not resolve them. Neither
deployment nor warm-cache passes establish stable 500-user or thousand-member
E2EE capacity. Production capacity testing is outside this rollout.

The reviewed one-release scripts and sanitized results are kept under
`docs/verification/artifacts/2026-09-10/media-production-release/`. Their fixed
release paths/image IDs are intentional; prepare a newly reviewed release for a
future deployment rather than rerunning activation over changed production state.
The actuator's automatic rollback uses the still-active deployment smoke sessions.
After cleanup logs them out, a later manual rollback must obtain fresh dedicated
verification sessions first; archived smoke tokens must not be reused.

Before closing the release, reconcile preserved production-only routes into the
server template and prove a render round trip equals the live configuration.
Also install the verified renderer's worker mapping. Run `--check
--require-production` without rewriting live configuration. This release preserved
iOS calls, platform download routes and the Getui selector, all previously missing
from the older server template. Keep these reconciled server sources in the next
release's drift review; do not overwrite them with an older local template.
