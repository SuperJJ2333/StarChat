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

## Verified re-signing input

Source `80d2510ec54c13f62ebc12bb3b19f662aaa320b2`; [signed build 34345558101](https://github.com/SuperJJ2333/StarChat/actions/runs/34345558101) passed. CI verified the actual code signature, production APNs entitlement and SQLCipher load order. Local inspection independently verified version, minimum iOS 16.0, iPad support, native library presence, background declarations and exact published Android HTML bytes.

File: `ChatFlow-0.3.69-build2073-AppStore-for-enterprise-resign.ipa`, 58,881,999 bytes. SHA256 `713219b85d015371986b32276f98f6de690a499bac5f7bbc79e49badbc336aa5`. A checksum-verified delivery copy and signing instructions are in the primary workspace's `docs/verification/artifacts/2026-09-09/unified-mobile/` directory. This is not an enterprise installation package and has not been published.

Native simulator run `34344059914` on the earlier merged application source hit the seed step timeout on both iOS 18 and 26. Xcode compiled successfully, Runner emitted a VM service and continued running, but no tests executed and no seed database was produced. The downstream missing-database check therefore does not establish a storage regression. The exact attach/bootstrap stall was not identified from nonverbose logs. A workflow-only follow-up adds verbose tracing; no IPA/application source was altered by this instrumentation. Simulator success is not claimed until the follow-up completes.

## Final native results and remaining handoff

The final IPA source `80d2510e` completed [native run 34345558069](https://github.com/SuperJJ2333/StarChat/actions/runs/34345558069) successfully on **iPhone 15 / iOS 18.6 and iOS 26.2**. Downloaded logs on each runtime show 15 seed/media tests and 2 new-process verification tests passing. Coverage includes M4A/AAC/WAV decoding and playback through the production voice engine, H.264/HEVC video playback through the production cache resolver, and retained Keychain/session/SQLCipher reads after process restart. `native-proof.json` records exact runtimes and log assertions.

These are synthetic simulator checks; microphone hardware, enterprise re-signing upgrade continuity, live push/CallKit and a full scanner-enabled plugin combination are not established by them. The scanner is explicitly omitted only from the simulator harness because its MLKit dependency lacks the required slice. Earlier attach stalls remain recorded, with no unproven root cause or claim of a storage defect. The unchanged final application source passed without a speculative app fix. The extra verbose diagnostic run is superseded by this successful final-source verification; the verbose workflow remains useful for future failures.

All code and verified re-signing input are ready. **Website enterprise publication is pending the external signed IPA.** No enterprise signing identity was available in the known local signing locations; personal App Store signing cannot replace that handoff. Android has the same shared source fixes, but its new package has not been built/published, preserving the user's requested iOS-first release order and the currently published Android 2072.
