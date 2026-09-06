# Cached entry boundaries

Decision: implement the user's cache-first UI requirement without changing authentication, E2EE key recovery, or server permissions.

- Before remote session restoration completes, only a read-only Messages projection may render. It requires the locally stored business Matrix ID to exactly match the restored Matrix account. IgnorePointer prevents interactions; preview mode performs no member loads, presence writes, invitation joins or sync initiation. Missing/mismatched identities show an empty Messages shell, never another account's cache.
- Authenticated interactions begin only after existing business restoration and identity checks pass. Matrix network synchronization then continues while the restored room list remains visible. Invalid tokens still leave the authenticated page. Generation checks prevent late restoration/cleanup from mutating a later login or restoring a logged-out session.
- Canonical direct-room caching stores server-issued room IDs per account/peer. It does not cache authorization or encryption decisions. Every opened room must still be encrypted and contain exactly the requested peer and the current account. Background directory refresh updates the next lookup; stale unsafe rooms cannot be opened. New room registration remains authoritative and idempotent.
- Favorite previews are locally generated small static images encrypted with AES-GCM using a secure-storage key. Original Matrix media ciphertext/E2EE payloads remain unchanged. Preview bytes are never sent in place of the original animation. Metadata cache uses the same local security boundary.
- New Moments metadata is exposed only through the existing authenticated API and VisibilityPolicy; no private content is sent to Matrix or returned in the metadata endpoint.

Review: independent domain/specification and quality/security reviews checked identity matching, read-only behavior, requested-peer validation, logout races and cache-write races. New regression tests preserve these boundaries. User authorized the behavior changes in the five-item follow-up; no relaxation of authentication or E2EE was requested or implemented.
