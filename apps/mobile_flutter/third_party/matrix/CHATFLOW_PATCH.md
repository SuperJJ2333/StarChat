# ChatFlow integration patch on Matrix 0.34.0

Upstream package: matrix 0.34.0, existing locked dependency from pub.dev mirror.
Original LICENSE and attribution retained. Vendored lib tree is unchanged except
`lib/src/voip/call_session.dart`, `lib/src/timeline.dart`, and the attachment
preparation changes documented below; see the source hashes
in the verification records.

Incoming 1:1 invite initialization used to acquire camera/microphone before
VoIP delivered the call to the application. Missing permission threw before any
incoming UI could be presented. Local media capture is now deferred to answer(),
which the application calls after explicit media permission consent. Outgoing
capture, group-call stream flow, signaling payloads and encryption are unchanged.

Answer preparation coalesces concurrent requests, preserves ringing on media
acquisition failure, and disposes media arriving after call termination. Four
existing fire-and-forget futures are explicitly marked unawaited and an existing
single-line conditional is braced to satisfy the retained upstream analyzer
configuration; these are not behavioral protocol changes.

Regression tests live in the application:
`test/features/matrix/incoming_sdk_media_test.dart`, plus controller/UI/native
permission-recovery tests. Do not replace this local dependency with stock 0.34.0
without re-running the missing-permission regressions. On upstream upgrades,
review whether the fix is upstreamed, rebase the minimal diff and record its
provenance; do not edit a developer pub-cache as the only persistent fix.

2026-09-07 timeline ordering: a synced event must not be replaced by a late
local sending/sent/error update. The previous merge kept the synced status but
replaced the server timestamp and payload with local data when /sync arrived
before the HTTP send acknowledgement. Ignore those lower-authority updates;
subsequent synced updates still apply normally. The change does not modify
transport, encryption or outgoing payloads. Real Timeline stream regressions:
`test/features/matrix/sdk_ack_order_test.dart`.

2026-09-09 content-addressed attachments (ADR-0060):

- `lib/src/utils/crypto/encrypted_file.dart` exports `encryptFileWithKey` with
  explicit 32-byte AES key and 16-byte IV validation, standard Matrix v2
  unpadded encodings and SHA-256 of ciphertext. Random `encryptFile` remains.
- `lib/src/utils/matrix_file.dart` accepts an optional `preEncrypted` envelope
  on every concrete media type. `bytes`, MIME, size, image dimensions, blurhash,
  video dimensions/duration and audio duration remain plaintext preview metadata;
  `encrypt()` returns the same prepared envelope on retries.
- `lib/src/room.dart` refuses prepared attachments without file E2EE and skips
  image/thumbnail transformation for a prepared original. The application must
  finish body transformations and thumbnail generation before preparation.
  Upload uses only the envelope ciphertext, filename `crypt`, and octet-stream
  MIME; content hashes exist only in the subsequently encrypted room event.

Application regressions: `test/features/matrix/content_addressed_media_test.dart`
exercises independent HKDF vectors, standard SDK decryption, actual
`Room.sendFileEvent` ciphertext uploads, retry identity, media metadata,
preprocessing order, decrypted-event authority and validated content caches.
This patch does not change Megolm rotation, room encryption or avatar uploads.
