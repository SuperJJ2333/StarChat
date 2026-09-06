# Mi 6 feedback fixes — 0.3.44+47

Scope: the eight user-reported issues. Branch `codex/mi6-feedback`, based on `d5c3471`. No business API, financial logic, or Matrix cryptographic protocol changes.

## Behavior and acceptance

1. GIF selection inspects the actual GIF87a/GIF89a signature. Known files are checked using only their 10-byte header and length before reading the full payload. Files above 20 MiB or 4,194,304 canvas pixels are rejected with a specific message. Original bytes are preserved; GIF never enters the native JPEG compressor. Bubbles/grid decode within a 720×720 fitting box; full viewer uses GIF 720/static 2048. Animation and aspect ratio remain intact. Ordinary images use thumbnails first; missing/failed thumbnails fall back to original. Oversized received GIFs cannot reach the image codec. The original payload remains available to the viewer for downloading. Verify with a normal animated GIF, a mislabeled GIF, and an oversized GIF on Mi 6; do not expect all old devices to be covered by automated tests.
2. Failed local events sort by timestamp rather than SDK failure priority. The red exclamation cancels the old local entry and creates a new sending attempt at the new timestamp; repeated taps are deduplicated. The original Matrix transaction ID is retained for network idempotency. Text/reply/mention payloads and uploaded encrypted attachments are preserved. Missing pre-upload file caches retain the failed bubble with a retry error. Verify offline send → send another message → first failure stays in place → retry → one new attempt, no duplicate old failure.
3. Search/calendar callbacks pop directly to the captured RoomPage route. The calendar no longer performs an additional pop. Loaded but offscreen messages are sought through the lazy list, made visible and highlighted; history is fetched only when the event is not loaded. Deleted local/recalled messages are excluded. Regression covers 180 variable-height rows in both directions without mounting the full timeline.
4. Search member selection and inline @ selection use actual avatar widgets. Custom contact avatars take precedence; remarks then nickname then username determine member names. Pinyin sorting/filtering remains shared.
5. Images/videos use a date-grouped, lazy three-column thumbnail grid with video play/duration indicators and actual media viewers. Sender avatars/names are omitted from these cells. Paging remains available. Image thumbnails and video poster extraction use separate loaders.
6. Discovery: Moments, then Scan.
7. Invitation entry is inside Personal Information before nickname. Populated nickname/signature fields align right; empty hints align left.
8. Me has both its existing header entry and an explicit Personal Information row, both opening the same working editor.

## Verification

- Final full Flutter suite: **1157 passed** (`flutter-tests-final.log`).
- Full analyzer: no issues (`analyze-final.log`).
- `scripts/verify.ps1`: PASS, including repository/deployment policies, 17 infra, 28 Getui, 9 bot, 338 business API (19 skipped), 60 mobile boundary tests, UI contract drift (17 components/330 screens), imports/AST, migrations, OpenAPI, Compose rendering.
- Existing external dependency warnings remain: Python Starlette/httpx and Pydantic deprecations; Android plugin Kotlin migration/deprecated API notices. No new source analyzer warnings. Skipped business tests require unavailable external services; no production migrations were run.
- Independent specification review covered profile/Discovery and search integration; independent quality review covered retry SDK behavior. Red/green evidence for new failures is under the task artifact directory.
- Real network sends/retries to another person's account were not performed by the agent. Device installation/startup and the user's subsequent live chat testing complement automated coverage.

Artifacts are local only: `docs/verification/artifacts/2026-09-06/mi6-feedback/`. No APK, signing keys, credentials, device databases, or message logs are committed.

## Design record

Existing WeChat-style tokens/components are reused. The local component registry and export ledger record this revision. Figma tooling is unavailable in this session; no remote Figma changes or synchronization are claimed.

## Delivery

Standard ARM64 debug uses versionName 0.3.44 and split versionCode 2047. Source build includes the existing HTTPS Business API, Matrix and Getui defines. Final delivery follows Apktool 2.12.1 full rebuild, build-tools 36.0.0 alignment/signature verification and code/manifest/native asset comparison. The current Mi 6 debug certificate is retained under the user's existing explicit authorization to preserve application data.

Final APK: `final/ChatFlow-0.3.44-arm64-debug-rebuilt.apk` below the task artifact directory. SHA256 `1cbf164d157b4268b2b45c9eb249278dd7a9a3bb3455d8eeb8bdd0f29047cba3`. Mi 6 `adb install -r` succeeded, installed version 0.3.44/2047 and on-device APK hash match. App started and remained running; its crash buffer contained zero fatal markers at verification time. No uninstall/data clearing was performed. Signer SHA256 `34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1` matches the previous installed debug APK. This startup check does not replace manual GIF and real network retry acceptance.
