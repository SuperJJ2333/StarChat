# Server-managed Matrix group membership plan

**Status:** Approved
**Date:** 2026-08-22

## Goal
Create Matrix rooms on the initiating device, then make the business API verify every selected business friend and use short-lived per-user Synapse sessions to join opted-in invitees before reporting completion. Account and Privacy exposes a default-enabled `是否自动允许加入群聊` preference.

## Data and flow
1. `users.auto_allow_group_join` is non-null and defaults to `true`.
2. Client creates encrypted room, posts room ID plus selected business user IDs to `/groups/auto-join` with an idempotency key.
3. API validates creator and invitees are active Matrix-backed friends; only invitees whose setting is enabled are joined. It obtains an unpersisted short-lived Synapse access token per invitee, calls the Matrix client join endpoint, then requests room membership and returns joined/pending IDs.
4. Client only opens the room after local Matrix sync, so its mosaic/title use synchronized joined membership.
5. API writes audit/outbox IDs and transitions only; it never reads encrypted content or stores user sessions/tokens.

## Verification
Backend tests cover default/updated privacy preference and reject non-friend or opted-out group joins. Flutter tests cover default switch and server membership coordinator invocation.
