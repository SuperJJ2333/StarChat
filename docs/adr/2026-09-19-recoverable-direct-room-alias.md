# Recoverable direct conversations and retained source rooms

Date: 2026-09-19. Decision authorized by the user's conversation reliability repair request and [approved plan](../superpowers/plans/2026-09-19-logical-conversation-reliability.md). Status: accepted. Domain/specification review identified and resolved legacy publication bypasses; independent quality/security review and staged production-merge review passed. Isolated PostgreSQL and production-image Synapse gates passed; the additive migration and API deployment were completed on 2026-09-19. See [server evidence](../verification/2026-09-19-direct-room-v2-server.md) for exact candidate and remaining client validation.

## Problem and decision

The legacy claim grants create permission exactly once. Losing that response before Matrix creation strands the reservation forever. Expiring it cannot establish that the original Matrix request will never complete. A client-created Matrix room is not a transactional business database operation.

The guarantee is one immutable canonical **logical** conversation and one confirmed sending destination. It is not a promise of zero physical Matrix rooms. Retain all verified source rooms and their existing encrypted history. The business domain never receives message bodies, attachment plaintext or room/recovery keys.

V2 claims reserve an opaque fixed Matrix alias (`chatflow_dm_` plus the reservation UUID without hyphens). Both participants and all their devices receive the same alias on replay. Clients resolve the alias before creating; a create request includes this alias and an initial empty-state-key `com.chatflow.direct_reservation` event containing `reservation_id`. After any timeout/error, resolve the same alias again. Do not create under a new alias or fall back to an unaliased room. Only the verified published canonical permits sending. Concurrent alias attempts can leave physical empty rooms depending on Synapse behavior; none is independently authorized to send. Collision errors are not instructions to generate another alias or invite repeatedly.

Publication verifies Matrix metadata: the profile service's exact two Matrix IDs are the only current joined/invited members, encryption is `m.megolm.v1.aes-sha2`, the reservation marker matches, and the configured homeserver resolves the fixed alias to this room. The request's `attempt_id` is an audit correlation identifier in V2, not sole creation authority. Pair locks serialize canonical publication and associations. Unavailable/mismatched evidence fails closed without resetting a claim.

## Legacy upgrade and retained history

The first V2 claim under the same pair lock replaces the reservation attempt with `alias-v2:<UUID>`. Legacy `/claim` never regrants `may_create`. Legacy `/publish` cannot publish before V2 verification. Once a canonical exists, late legacy publish validates the candidate's pair/encryption metadata, records it as a historical source and returns the canonical. It never overwrites canonical. This is publication fencing, not cancellation of a Matrix HTTP request already in flight. Older clients may still create physical rooms; those remain retained history.

Existing legacy rooms can be recovered before upgrading through `/recover` using authoritative pair/encryption evidence without alias/marker requirements. All new canonical writes through legacy registration and publication also require authoritative exact-pair/encryption evidence; arbitrary caller-supplied room IDs cannot preempt V2. When any canonical already exists, a different valid late legacy candidate is verified and retained as history, regardless of the reservation protocol or original creator, then the unchanged canonical is returned. Replaying the existing canonical remains compatible and does not demand new metadata to read it. Production repair should discover current candidate rooms from metadata and recover the existing appropriate room first. If no suitable candidate exists, upgrade to V2 and let participant clients resolve/create the fixed alias. Absence of candidates is not used to revive the old non-idempotent permission.

An additive `direct_conversation_rooms` table stores only pair IDs, room IDs and timestamps. Authenticated participants can register metadata-verified history and retrieve it from either device. Existing canonical rows are included in reads without bulk backfill. Historical rooms where a participant has left cannot pass the current active-membership evidence check; their existing client association/history is retained, but this endpoint does not infer former access from plaintext or grant new membership.

## Compatibility and rollback

Legacy API schemas remain unchanged. Existing canonical rows are immutable. New endpoints and the source-room table are additive. No change to authentication, cryptography, financial state or Matrix permissions is made.

Deploy migration `0070_direct_room_history` before enabling the new endpoints. Application rollback preserves the table, reservation fences and audit/outbox evidence; do not run destructive downgrade or remove a canonical. Rolling back to legacy-only code pauses recovery for upgraded pending reservations but never reauthorizes legacy create. Restore the reviewed V2 implementation to resume. Read-only metadata repair and canonical proof must precede any later manual intervention.

## Verification boundaries

Focused tests exercise lost claim response, lost creation response (room exists but publication unknown), lost publication response, opposite/concurrent claims and publication, late legacy creators, exact-member/encryption/alias/marker rejection, Matrix unavailability and immutable history associations. PostgreSQL concurrency and real Synapse alias collision behavior require the production deployment's isolated integration gate; unit simulations do not claim those live results.
