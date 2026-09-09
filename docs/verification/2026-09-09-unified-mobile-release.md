# Unified mobile 0.3.69 / 2073

## Scope and provenance

User approved synchronizing published Android 0.3.68 / 2072 business functionality into iOS while retaining the reviewed iOS compatibility/history/direct-room fixes, distributing iOS through the existing website enterprise channel first, then delivering the same fixes to Android.

The isolated `codex/mobile-parity-20260909` source merges iOS baseline `afc9d15d39842db3e79b3509d746c499aec91db7` with published Android source `4912d062012f9bb1ae45f6c8ed5bf1d2735c26bf`. Unrelated root workspace changes are excluded. Flutter business code is shared; earlier release branches had diverged. Native audio, push, signing and installation remain platform-specific.

Android detail/replies/image comments, emoji, avatar identity, media deduplication, notifications, message-menu positioning and statistics changes are retained. iOS prepared feed first paint, account/revision isolation, serialized confirmed persistence, typed video playback, history/key continuity, coordinated direct-room creation and labeled friend acceptance context remain present. Detail reactions now persist confirmed liker names as well as counts.

The statistics HTML remains byte-identical to Android 2072: SHA256 `89eab23270dc87ce6fd07715d9abb2606455d94ce1fc16cd56d2deeaeeafb9d5`. Native iOS sources are unchanged from the reviewed baseline. Both source version defaults are `0.3.69+2073`.

## Local migration graph

Merging the two feature histories produced two local Alembic heads. Migration tests first failed with five failures/six passes; a no-DDL `0041_merge_mobile_parity` revision joins the two existing 0040 revisions. All 11 migration tests then passed. No production migration was executed for this graph merge. Production already has a separately reconciled `0057_merge_direct_room` graph; deployment must inspect that graph rather than run this local head blindly.

## Verification evidence

Raw technical evidence is under `docs/verification/artifacts/2026-09-09/unified-mobile/`, excluded from code delivery. Cache and Moments subfolders distinguish compilation-conflict failures from actual behavioral red/green regressions. Coverage includes Android cover migration into iOS preferences, signed URL/account transitions, image replies with pending likes, confirmed detail persistence after navigation, and detail-to-feed-to-disk liker identity.

Initial integrated Flutter suite: 1,555 passed; analyzer: no issues. Subsequent specification review found the detail liker-name omission and added two regression tests. Final verification and build results are recorded below when available. Matrix SDK encrypted H.264/HEVC exact-byte transfers and damaged-ciphertext rejection passed four tests; the old cache file-count assertion now excludes the new `.ref` metadata alongside `.len`, without weakening payload checks.

Specification review then passed after the liker-name correction. Quality/security review found a successful deletion could fail to persist after leaving detail; a delayed DELETE/navigation test reproduced it and the callback now persists outside the mounted UI guard. The final 61-test Moments subset and analyzer passed; reviewer recheck found no unresolved actionable findings.

Repository `scripts/verify.ps1` exited zero with `Verification: PASS`: business API/Worker 378 passed and 19 existing environment-dependent skips, mobile boundaries 66 passed, infrastructure 17, push bridge 28 and Matrix bot 9. Migration single-head/offline SQL, OpenAPI drift, UI contract drift, AST/import and Compose gates passed. Existing dependency deprecation warnings remain visible; they were not suppressed. No production database changes were performed by these checks.

Final integrated Flutter suite after both review corrections: **1,558 passed** (`flutter-release.txt`), analyzer: **no issues** (`analyze-release.txt`). Both specification and quality/security reviews completed with no unresolved actionable findings. Simulator and signed artifact results remain separate from these local checks.

Statistics browser regression passed Chinese amount input, duplicate suppression, confirm/cancel, undo, three state restores, double clear confirmation, zodiac operations/button recovery and bill merging with zero page errors. First invocation lacked Playwright resolution; rerun used the configured bundled runtime modules successfully.

## Distribution boundary

The user selected the existing website enterprise channel. Current CI uses personal Team `HY9Q7Q35S5` and an App Store profile, producing a re-signing input, not an enterprise OTA package. Existing website enterprise signatures cannot sign updated code. The external enterprise signing handoff remains required unless an authorized local signing workflow is provided. Validate the returned IPA's identity, signature, entitlements, native libraries, upgrade continuity and hash before changing website/manifest links.

Android 2072 remains the published release until iOS distribution is complete and the successor passes the documented Android rebuild/alignment/stable-signer gates. No Android publication is implied by merging shared source.

Remote Figma editing remains unavailable in this session; the existing component registry and explicitly deferred hotfix evidence are preserved. No remote design change is claimed.

## Build reproducibility correction

The first cloud build of `e02b9ad6` passed signature/native-library checks but local IPA inspection rejected its statistics asset hash. Git had normalized the CRLF Windows release resource to LF on macOS: source/Android bytes were 71,375 bytes with hash `89eab232...`; initial IPA bytes were 69,539 bytes with hash `9c3395dd14432313f4b0a60cb9c0ed7d3f59397c8de795a8b566e3ee7f1c673a`. Comparing normalized bytes proved line endings were the only difference. This candidate was not distributed.

A targeted `.gitattributes` rule now preserves that resource's exact bytes (`-text`, with `cr-at-eol` for whitespace checks). Renormalizing only that file made the Git index match the already-tested Android asset, with no semantic HTML or Dart changes. CI now asserts the resource hash before building and inside the final IPA. The fixed candidate is rebuilt instead of modifying an already-signed package.
