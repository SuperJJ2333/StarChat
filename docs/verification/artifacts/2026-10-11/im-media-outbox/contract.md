# R8 durable media integration contract

Owner: review_r1_r2. Candidate based on integration 4662f576d4c717f0a605e118ffe4c54da1226e5c plus media-budget 82a8eca515b81a8747d2a45ea6992a3b0af8a8d8 (local cherry-pick 03b22fc0). Approved scope is remediation plan R8 and original client-plan-notes B1/B2. No deployment or packaging.

## Storage, identity and bounds

`MediaOutboxOwner` uses the public MatrixLocalBinding account, homeserver and database generation. Its SHA-256 namespace does not depend on device rotation. Every admission and asynchronous send continuation checks the current session identity; a foreign account/generation cannot claim old work.

`SqliteMediaOutboxStore` owns a separate manifest-v1.db (SQLite schema version 2, additive upgrade from version 1) and sources/<opaque SHA-256>.bin inside pending-media-v1/<owner scope>. Metadata contains txid, room, opaque owner scope, filename/MIME, prepared/asFile, dimensions/duration, length/digest, stage, retry time, fixed failure code and accepted event ID. It contains no token, file/room key, arbitrary Matrix event content, caption or encrypted attachment descriptor. No existing Matrix/text-outbox tables are written.

Intent is committed before a deferred resolver/export/download or original-file copy begins. Copy is at most 64 KiB per chunk, with streaming SHA-256, flush and an internal .part-to-.bin rename. Queued is committed only after source sealing and digest completion. The original is never moved from outside the private root. Symbolic links/nonregular files are rejected before opening manifest, sidecars or source paths. Interrupted preparation is shown as source-incomplete and requires re-selection; it is not silently discarded.

The per-owner pending store retains at most 512 MiB of charged source bytes, admits at most 128 nonterminal tasks, and leaves a 16 MiB free-space reserve. Source length is reserved in a SQLite transaction before copying; failed and partially written files remain charged. Sent/canceled sources release their charge only after deletion succeeds. Every admission re-queries native capacity/protection. A disk failure preserves the selected original and an actionable intent. This is a per-owner source budget, not an aggregate quota across old accounts or a cap on tombstone metadata. Existing media-transfer memory limits remain independent and explicit to the user.

Failed sources remain available for retry. Explicit cancel tombstones the task; account suspension does not cancel/delete it. An active copy or true transport pins the source until it settles. Cache indexing, eviction and cache cleanup cannot discover this independent directory.

## Production integration

AppHome binds the service only after managed Matrix startup and local identity reconciliation, using the secure public local binding and a generation/epoch check. Existing network/resume hooks trigger discovery. Suspension stops new work; late completions cannot publish for another owner. Recovery authorizes the target again and opens a temporary room lease without navigation.

RoomPage file, camera, voice and nonlocal-gallery paths persist before their existing send admission. Edited images use enqueuePreparedMediaFrom: a durable intent precedes the actual export. Matrix early hooks cover single/batch video resolvers and media forwarding, before coordinator enqueue. Video originals are copied before admission, then can be prepared again after restart. Forwarding downloads/decrypts only under the existing permission/E2EE and memory-budget checks; only final source bytes and whitelisted presentation metadata enter private pending storage. A managed production session with no valid durable service fails closed. Legacy unmanaged SDK fixtures retain their previous path; this is not a production cache fallback. Flash photos keep their existing no-plaintext-disk path.

Coordinator queue closures retain tasks and small metadata, not prepared attachment buffers. Production sendPersistedMedia uses the existing MMS APIs for raw originals and a room-lease sendStoredMedia path for already prepared originals. The prepared/asFile flags, dimensions and voice duration survive reopen: a file-selected image remains m.file, and an already prepared video is not transcoded a second time. Optional thumbnails may be regenerated; they are not durable encryption descriptors.

Foreground and recovery share one live Future per (owner, txid) and two real transport room slots. Same-room admission is ordered; a hanging room does not block another eligible room. recover() holds its discovery lock only through scan/admission, never through transport lifetime, so retries and newly persisted work can fill a free slot. Future observers consume failures without mutating a later attempt. No UI timeout releases ownership or quota. Previous-process sending becomes ACK-unknown; every retry retains txid. SDK may re-upload ciphertext after an uncertain ACK, but the event request retains its original transaction URL. Hard server retry deadlines survive manual retry. Offline retries are bounded; permission, malformed input and explicit memory-limit errors require user action.

The room pending-attachment banner exposes failed/restored tasks with fixed failure text, retry and cancel. Cancel explicitly cannot recall an event the server already accepted. New prepared media still passes current server/memory limits when dispatched.

## Native contract and release gates

Channel chatflow/media_storage provides pendingMediaDirectory() -> {path, availableBytes, protected, backupExcluded}, and sealPendingFiles({scope: 64hex, sourceId?: 64hex}) -> {protected, backupExcluded}. All paths are native-fixed. seal targets only manifest-v1.db and journal/WAL/SHM plus sources/<id>.bin(.part); no arbitrary path argument is accepted. Missing/unprotected/unavailable native storage rejects admission without a cache/temp fallback.

Android native owner uses credential-encrypted Context.noBackupFilesDir/pending-media-v1. iOS native owner uses Application Support/pending-media-v1 with CompleteUntilFirstUserAuthentication, backup exclusion, explicit sealing and read-back checks for newly created files. Root owns both native implementations and release validation. This change does not claim those platform policies were exercised on Windows.

The native integration fixture uses the real channel, default FFI SQLite factory, protected source copy, reopen, prepared/asFile restoration and cancellation cleanup, with only synthetic bytes and no Matrix credentials/network. It must run against the actual Android/iOS candidate before platform acceptance. Root owns full integrated Flutter/monorepo gates and release builds; this candidate does not authorize or claim release completion.
