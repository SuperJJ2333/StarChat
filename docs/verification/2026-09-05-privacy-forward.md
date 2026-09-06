# Friend request privacy and forwarding repair

Approved plan: `docs/superpowers/plans/2026-09-05-forward-confirmation.md`. Figma synchronization deferred under the user's existing authorization.

## Behavior

Incoming friendship request projections never return the requester's private remark/tags; outgoing projections retain the owner's values. The acceptance page ignores old-server private fields, and acceptance does not copy them into the recipient's contact cache. Existing legitimate owner preferences are preserved. Previously disclosed information cannot be recalled; ambiguous historical preferences are not destructively purged.

Forwarding remains an independent chat picker. Rows and recent avatars have Cupertino press animation; recent selections respect multi-select. A bottom card displays recipients, content preview, cancel and confirm. Sending starts only on confirmation, disables duplicate taps/back navigation while pending, and reports failures without leaving the picker. Cancellation does not report success. Acknowledged message/recipient pairs are skipped during batch retries. Groups use authenticated member avatars in mosaics with asynchronous loading and visible offline fallback.

## Specification then quality review

Separate review confirmed requested privacy and forwarding behavior; discovered and fixed an existing unsupported video type in the actual forwarding transport. Videos now use the existing local-decryption/encrypted-room upload path and retain filename, MIME, dimensions and duration. Source attachment/thumbnail descriptors are never copied. Video transport regression coverage: 14 tests passed (including existing interaction tests). No E2EE, financial, authentication or API schema changes. No message contents or private preferences logged. No unrelated production code deployed.

The independent reviewer rechecked the video fix and closed the P2 finding. Final focused analysis passed. No real messages or friend requests were sent during verification; recipient delivery and visual behavior still require the user's real-device test.

## Verification

- Backend friendship: 39 passed with red/green privacy evidence.
- Final integrated Flutter privacy/picker/avatar/video/interaction tests: 33 passed, including six picker tests (animation, cancel, retry, pending-send/back guard and multi-select).
- Focused Dart analysis: no issues.
- Repository verify: backend/worker 338 passed, 19 skipped; mobile boundaries 47 passed, 4 existing call-boundary failures. These match the previous turn's failures. Full gate is not green.
- UI contract: PASS (17 components, 330 screens). OpenAPI drift: PASS. Git diff whitespace: PASS.
- Production single-file overlay compared exactly against the running image's previous service.py; only owner filtering/comment changed. Container `starchat-business-api:privacy-20260905-owner-fields` is healthy, deployed source SHA256 matches local `6dedea1d91cd3a11fd4d0ff351fecfee79ffba4b5f04bf49c3f9632de95cf5ba`. Migration remains `0036_group_join_tokens`; no migration run. Server-only backup and image/source rollback retained under `/opt/starchat/releases/privacy-20260905-owner-fields/`.

Detailed logs: `docs/verification/artifacts/2026-09-05/privacy-forward/`.

## ARM64 debug artifact

Built from source, standard debug flavor, no obfuscation/packing: `ChatFlow-0.3.37-arm64-debug-privacy-forward.apk`, versionName 0.3.37, versionCode 2040, only arm64-v8a. SHA256 `8d842893d3f2a0527fbd8775921cc9a323cc4e90504a8d411565321751e0cdce`. Flutter build passed; existing plugin KGP migration warning remains (future Flutter compatibility, not a build failure). No release update notification published.

MI 6 `cbd0156b`: initial streamed install stalled at 77%; stopped only this APK's adb process, then `install --no-streaming -r -t` succeeded. No uninstall/data clear. Package update time `2026-09-05 16:54:19`; installed base.apk SHA256 exactly matches the artifact above. MainActivity launched. `device-install.log` records successful non-streaming install. Attempted abandonment of the stopped streaming session returned no-access after termination; no permissions were changed to bypass it.
