# Startup Local Projection Implementation Plan

> Use subagent-driven-development for one coherent cross-module implementation task, independent specification then quality/security review, followed by root-owned delivery. User already approved the four-point design and original emulator delivery; continue without another permission loop.

**Goal:** Valid cached account opens a real interactive messages list and rooms before full SDK initialization, including durable text pending.
**Architecture:** Opt-in staged initialization on the same Client/Room identities; existing SQLCipher projection reads at most40 recent rooms and required bounded states first. Keep minimum installation/identity/key/Olm safety; defer device-key collections, remaining rooms and optional data/network, and do not mark dispatch verified until full initialization settles.
**Tech:** Flutter/Dart, vendored Matrix, SQLCipher, Android Debug.
**Spec:** docs/superpowers/specs/2026-10-17-startup-local-projection-design.md.

## Constraints / ownership

- Same isolated tree7747e54a (productc29597e0). Root docs/version/packaging; startup_pipeline sole product writer; reviewer read-only after freeze. No child agents by implementer.
- Preserve normal create/login defaults and security/crypto semantics. No new plaintext persistence, destructive migrations, schema/financial/auth contracts. Migration/missing/corrupt identity may use existing safe recovery UI; validcached path must not await fullSDK.
- Initial room projection<=40; room recent event head<=40 reused. Full hydration never replaces active Room/controller/page/anchor/pendingtxid; cancels stale account/generation/disposal results. Remaining rooms may expand in background.
- Existing real local account checks precede localCacheReady; business verified dispatch additionally waits initializationCompleted. Failure handling must not leave fake ready capability or unhandled detached-future errors.
- Evidence only docs/verification/artifacts/2026-10-17/startup-local-projection/. ShellpwshUTF8, PythonUTF8. No messages to real recipients. Native tests synthetic isolated data; install-r only.
- Previous2218 passes are baselines, not evidence of this corrected cold-start behavior. Resource-limited host: focused concurrency1, no concurrent Gradle/fulltest.

## Review focus

1. Bounded SQL queries include only selected room IDs, not loadall then take40; selection/order/cache visibility is correct.
2. Partial Client readiness never becomes network send/auth authority; full init errors/revocation invalidate local routes.
3. Full room merge preserves object identity and live updates, with safe handling of newly created/removed/hidden rooms.
4. Cold-entry tests traverse actual main, installation gate, factory, bootstrap, AppHome, RoomPage; held fullSDK does not implicitly release before assertions.
5. Cache scope and pending journal stay consistent across startup, retry, account switch and disposal; no duplicate txid/network send.

## Task1: Staged local startup and actual-entry acceptance

**Owned files:** apps/mobile_flutter/third_party/matrix/lib/src/client.dart; src/database/database_api.dart; src/database/matrix_sdk_database.dart; apps/mobile_flutter/lib/features/matrix/matrix_client_factory.dart; matrix_e2ee_client.dart; core/matrix_startup_client.dart; core/session_bootstrap_controller.dart; main.dart; core/installation_startup_gate.dart only if required; focused matching tests and integration_test/android_startup_local_projection_test.dart. Additional required product file must be declared to root before editing. Preserve LF SDK files.

**Interfaces:** Client.init optional bool localCacheFirst=false, localCacheReady and initializationCompleted completion interfaces; concrete future ownership/error delivery documented in report. MatrixClientFactory.createForStartup() returns sameClient once safe bounded projection available, normal create unchanged. MatrixSdkE2eeClient/public session interface exposes complete initialization barrier with immediately complete default for ordinary fakes/clients. Bootstrap announces local eligibility first, awaits full barrier before authenticated dispatch. main test dependency seam defaults production, injects platform/store/factory/API adapters only and must call actual production main composition. Names can be adjusted only with root-notified equivalent semantics.

- [ ] RED: genuine persisted SQLCipher fixture with>40 rooms; hold full initialization device-key/allroom stage. Assert factory returns within local projection while full completionpending, <=40 local rows and no allroom scan; data/keys no unauthorized exposure.
- [ ] Implement opt-in sameClient local-ready stage. Existing minimum encrypted identity/Olm path retained; guarded full continuation merges Room identity. Preserve defaults/source compatibility. Add error/dispose/accountgeneration and defaultnormal-init regression cases.
- [ ] RED at app.main: real stored eligible identity + synthetic API; hold full initialization, advance beyond3seconds, assert real cached messages list and no business full-screen loading; click tabs, enter cachedRoom, scroll actual viewport, durable textpending with network send0. Explicitly prove barrierstillpending at each assertion.
- [ ] Wire actual main to createForStartup and session readinessbarrier. Full recovery merges same page, preserves anchor/pendingtxid; releasebarrier and existingpermissionchain sends exactlyonce. No static screenshot/new mockhome shortcut.
- [ ] GREEN failure/retry/logout/accountswitch/hidden/redacted/corrupt/no-cache cases; preserve safety UI only where necessary. Input enabled only when existing safe durable queue ready.
- [ ] Package native integration target using same test scenario and real AndroidSQLCipher synthetic isolated fixture; no liveaccount store mutation. Emit safe counts/timing only. Host tests must use real IO runner where FakeAsync otherwise hangs.
- [ ] Run focused tests/analyze, source diffcheck, commit ownfiles; report exact red/green commands/exit/native hashes, commit/filehashes, lifecycle decisions and remainingissues. No fullsuite/build/install by worker.
- [ ] Root independent SPEC→QUALITY review, resolve blocking originalscope findings before sharedfull.

## Task2: Frozen verification and emulator delivery

Root owned docs/pubspec/AppConfig/iOS metadata parity as version contracts require; no iOSbuild. Candidate0.4.50+2219 subject fresh installed/source reservation check. Preserve signer75b31, x86_64debug.

- [ ] Focusedboundary/UIregistry impact checks and verify.ps1environmentpreflight; fullFlutter/analyze only afterTask1reviewPASS, save source/lock/native identity.
- [ ] Build conventional-rebuilt/fixed-signed synthetic native integration target; drive test on emulator with real entry delays and assertions, preserve realuserdata. Record outcome honestly. Reuse identical host gates.
- [ ] Build ordinarymain source once, Apktool2.12.1→zipalign36-P16→fixedsign→semantic/nativeasset/manifest/signature checks. RawAPK is intermediate.
- [ ] install-r ordinarymain; compare UID/firstInstall/version/baseAPKhash; coldlaunch actualUI observation, no humanmessage sending. Keep native synthetic test evidence separate from realuserdata smoke and Debug performance separate from profileperformance.
- [ ] Update task/currentstate/report, timings and links; clean onlyownedmaps/processes. Keepworktree/artifacts; no productionpublish/merge requested.
