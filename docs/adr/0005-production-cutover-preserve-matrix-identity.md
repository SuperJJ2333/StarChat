# ADR 0005: Production cutover preserves Matrix identity and uses logical database restore

- Status: Accepted
- Date: 2026-08-18
- Decision owners: Product owner and implementation agent

## Context

The running development deployment contains the authoritative Business
PostgreSQL account/ledger data and the authoritative Synapse PostgreSQL room
state. Matrix also depends on its existing `matrix.localhost` server name,
signing key, media store, and cryptographic secrets. The target server
`207.56.8.8` is an empty Ubuntu host and will expose the approved
`liuhetong888.com` HTTPS gateway.

Copying live PostgreSQL data directories between Windows bind mounts and a
Linux host is unsafe. Changing Matrix `server_name` would create different
user, room, and MXC identities and is not a URL migration.

## Decision

1. Use an announced write outage. Stop API, worker, bot, Synapse, Element and
   TURN writers before the final export.
2. Export both PostgreSQL databases with PostgreSQL custom-format logical
   dumps after writers stop. Restore into fresh PostgreSQL 16.9 containers.
3. Preserve `MATRIX_SERVER_NAME=matrix.localhost`, the existing Synapse signing
   key, Synapse media store, Matrix database, bot store and identity-critical
   secrets. Only the public client URL becomes `https://liuhetong888.com/`.
4. Preserve the Business database, private media and secrets required to
   validate existing password hashes, JWT sessions, pending verification
   links and signed media URLs.
5. Generate new production-only infrastructure credentials where continuity
   is unnecessary. Do not commit or print any secret.
6. Restore and validate on the target before declaring cutover. Keep the
   stopped source intact as the rollback source until acceptance completes.
7. Do not derive ledger or wallet state from Matrix during migration. Database
   dumps remain the only source for business financial state.

## Consequences

- Existing Matrix IDs remain `@user:matrix.localhost`; clients reach them
  through the new HTTPS homeserver URL.
- Existing sessions can remain valid when identity-critical secrets are
  preserved, although clients may need one reconnect after the outage.
- The application is unavailable during export, transfer, restore and
  validation.
- New email registration is not considered production-ready until a real SMTP
  provider is configured; migration and existing-account login are independent
  of that provider.

## Rollback

If target validation fails, stop target writers, leave target data for
forensics, restart the unchanged local deployment and report the failed
cutover. Never resolve rollback by changing Matrix `server_name`, weakening
E2EE, editing ledger rows, bypassing TLS or exposing internal admin endpoints.
