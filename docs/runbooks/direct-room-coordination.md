# Durable direct-room creation

The mobile client uses the authenticated business account pair, sorted by the API, to claim permission **before** asking Matrix to create a room. `direct_room_reservations` has one unique row per pair. Claims, publication and legacy registration all acquire the same database row lock.

`POST /direct-conversations/claim` accepts `peer_user_id` and a persisted `attempt_id`. A first empty reservation returns `may_create=true, can_publish=true`. Replays never grant creation again. The owner can publish/recover with its same attempt; other devices wait for `matrix_room_id`. `POST /direct-conversations/publish` requires the same authenticated owner and attempt, validates immutable publication, and returns the canonical room. Legacy registration returns the first room and rejects an active pending reservation.

Client intent storage is account/peer scoped and stores only the attempt and room IDs. Persisting the attempt must succeed before requesting a grant. Existing safe Matrix rooms are reused; an invalid room, unknown identity, failed directory query or uncertain create result is not permission to replace it. The client persists the created room before publication. A retry can republish that result or find an existing safe joined/invited room; it cannot issue another create using a replayed grant.

## Deployment order

1. Review the actual production image and migration graph. This branch adds `0040_direct_room_reservations` after `0039_merge_settings_wallet`; production has a divergent, newer migration chain. Integrate this additive table into that graph without replacing unrelated production code or running an old branch's whole migration chain.
2. Deploy the reviewed API and verify claim/publication/legacy compatibility against isolated test identities. New clients require these endpoints and intentionally fail closed against a server without them.
3. Build and distribute new Android/iOS versions from the same reviewed source. Existing 0.3.58(61) artifacts and the old website enterprise IPA are not updated by source changes.
4. Test two devices accepting/opening the same friend concurrently, network loss during create/publication, restart recovery, and both parties reading the same history. Do not use real private content for diagnostics.

## Ambiguous creation and rollback

A pending reservation has **no automatic expiry or takeover**. An expired network timeout cannot prove Matrix did not create a room, and a delayed creator may still finish. Inspect only technical account/room/attempt identifiers. Retry from the original owner's installation after sync to recover its persisted or existing room. Never delete/reset a pending reservation merely because it is old, and never wipe local history or keys to repair this condition. If no result can be established, require explicit reconciliation; this implementation chooses a visible retry state over a possible duplicate room.

The migration deliberately refuses a table-dropping downgrade: removing uncertain reservations can reauthorize duplicate creation. Application rollback must preserve the table and keep canonical mappings immutable. Rolling back to clients/APIs that bypass coordination loses the new guarantee, even if the table remains. Existing duplicate Matrix rooms are retained for history; no merge, deletion, redaction or encryption-key migration is performed.

## Friend request context

On acceptance, the accepting client sends an encrypted `com.changliao.friend_accepted` system event containing a labeled original request explanation before opening its composer. It does not impersonate an ordinary requester message. The request ID determines a stable transaction ID. Outgoing request polling only refreshes contact metadata, including after upgrades/restarts; it never replays the greeting as ordinary text.

Failure leaves friendship saved and offers an explicit initialization retry. The accepted request detail also offers opening the chat after restart, first verifying that the peer remains a current friend. Retrying does not repeat acceptance or create a second system event in the same room. Offline/network failure is surfaced, not presented as successful immediate delivery. Older clients may still execute their old polling logic until upgraded.
