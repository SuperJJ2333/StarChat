# Direct-room V2 deployment and metadata recovery

Follow [production workflow](admin-production-workflow.md) and [ADR](../adr/2026-09-19-recoverable-direct-room-alias.md). User authorization for this task includes necessary production repair; root owns deployment.

## Overlay and database

Overlay only these business API paths from the reviewed candidate: `app/api/friendship.py`, `app/integrations/matrix_admin.py`, `app/main.py`, `app/modules/friendship/{models.py,service.py,direct_room_recovery.py}`, and `migrations/versions/0070_direct_room_history.py`. The unchanged `direct_room_coordinator.py` must exist in the base image. Do not replace unrelated production modules from this working tree.

Read current image/config/schema first. Ensure the current schema has `0069_media_platform` before upgrading to `0070_direct_room_history`; do not silently execute unrelated intermediate migrations. Back up database/config to the protected host directory and validate an isolated restore. The migration only adds `direct_conversation_rooms`, foreign keys and a pair/room unique constraint; no bulk data mutation. Keep this table on application rollback. Test PostgreSQL pair concurrency on the isolated clone, not production users.

## Contract

- `POST /api/v1/direct-conversations/claim-v2`: `{peer_user_id, attempt_id}` (UUID), returns legacy claim booleans plus `room_alias_localpart` and `reservation_id`. Replay always returns the same pair alias; `matrix_room_id` immediately wins when present.
- `POST /api/v1/direct-conversations/recover`: `{peer_user_id, attempt_id, matrix_room_id}`, returns the immutable canonical after metadata verification. V2 first publication requires fixed alias and reservation marker in addition to exact pair/encryption evidence.
- `POST /api/v1/direct-conversations/associations`: `{peer_user_id, matrix_room_id}`, verifies and remembers a historical room without replacing or creating canonical.
- `GET /api/v1/direct-conversations/associations?peer_user_id=...`: `{matrix_room_id, room_ids}` shared by both authenticated participants. Pair identity comes from the authenticated actor, never caller-supplied actor ID.

Client uses `#<room_alias_localpart>:<configured Matrix server name>` with createRoom `room_alias_name=<localpart>` and `initial_state=[{type:com.chatflow.direct_reservation,state_key:'',content:{reservation_id}}]` alongside normal encrypted private direct-room creation settings. Resolve first and after uncertain results. Publish through recover before sending any event. Preserve source-room/event anchors and retrieve verified associations on other devices.

## Operational recovery

1. Inspect reservation/canonical counts and candidate room metadata only. Do not dump profile IDs, room IDs, tokens or message content into public logs; sensitive per-pair evidence stays in protected host files.
2. For a pending legacy pair, inspect participant account-data room associations and authoritative room state. Existing encrypted exact-pair rooms are candidates. With multiple candidates, retain all through associations and select the existing intended representative using existing activity/association evidence, without deleting rooms. A canonical already present always wins.
3. Recover a verified legacy candidate using the public application service/API, which writes audit and Outbox transactionally. Never directly write canonical tables. If no existing candidate can be verified, V2 claim upgrades and fences legacy publication; new clients resolve/create only its fixed alias.
4. Late legacy registration/publication after any canonical is metadata-verified and retained as history, then returns canonical. All new legacy canonical writes require exact-pair/encryption evidence. If a V2 reservation has no canonical yet, legacy publication stays pending; it cannot bypass fixed-alias evidence. Existing canonical replays remain available when Matrix metadata is temporarily unavailable.
5. Validate health, unauthenticated 401 for all new endpoints, deployed source hashes, migration head/table, unchanged unrelated containers, and isolated response-loss/concurrency integration. Verify real Synapse alias collision behavior before claiming that integration gate passed.

No synthetic production user sessions, forced joins, room deletion, Matrix database writes or key resets are part of this repair. Exact-pair current membership checks deliberately reject unrelated members and left-only legacy rooms. The old client's ability to send directly to physical rooms cannot be revoked by business API fencing; new clients converge those histories logically.
