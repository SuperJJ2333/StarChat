# Android 2214 — 1. SPEC / domain independent review

**PASS for the exact existing-scope publication package.** No new specification/domain blocker was found. This is authorization for the reviewed operations, not a claim that publication has happened, all IM risks are resolved, or the final APK has passed ARM64 real-phone/16KiB acceptance. This final report supersedes the pending status in `review-entry.md`.

Reviewer: `/root/release_final_review`, independent of build/publication author. Order: specification/domain first, quality/security second. User authorization to fix, change, restart and deploy was already granted; root owns execution. This reviewer performed local read-only inspection and wrote only this review directory.

## Exact binding

- Source: `e9d297b2b49c8b2198fb3225bf7e04ed80ab4bd8`.
- Mobile input manifest: `f7a9a63d118bb39994907e6d37e8179ebe3f78cb75e18db6ac0141b96b29a687`; all **2101** files rehashed against the current root inputs.
- Package freeze: `b1abd1b18928d8f0306077bc64ff3d09f286b5af11c17a9344f877961abb8297`.
- Final APK: `575e24f4c841ed2388311ba19c06e23623838022ed2a438df6c56642436af614`, **73,336,097 bytes**.
- Runtime archive: `1be3d1abdf7da35e26e363ae786b5334e5cd279d620a6d56bb9dd33be5e7c0f5`, 50,486 bytes.
- Release record: `71fb3881034f9cb448d37eb7cafd67838497ce7a79cc27d2ae1532e8e35dabf1`.
- Operation ID: `im2214-e9d297-r3-20261011`.

## Specification and domain findings

1. Actual package is `com.liuhetong.mobile`, **0.4.45+2214**, standard ARM64 release, minSDK 24 / targetSDK 36. It followed source build, Apktool 2.12.1 conventional DEX/resource/manifest rebuild, alignment, stable signing, and final verification. All **28** recorded steps exit 0; every step log was independently rehashed. Raw Flutter output is not the delivery APK. No Dart/R8 obfuscation or icon tree shaking was introduced. The production HTTPS defines and exact lock remain bound.
2. Final signer is the existing user-tested `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`, one RSA 3072 signer, v2/v3 verified. The source/final decode reports show 25,414 identical smali classes, six rebuilt DEX files, 475 resource entries each, identical manifest semantics, and 274 unchanged native/asset entries. Independent ZIP readback confirmed all 274 bytes and unique entry names. Main activity remains unable to show over or wake the lock screen; the dedicated incoming-call path is preserved and automatic keyguard dismissal absent.
3. Bound shared evidence is **5958 PASS / 9 SKIP / 0 FAIL**, analyzer 0 issues, boundary **401 PASS / 1 SKIP**. Actual log hashes, exit codes and termination markers were checked. Search-media earlier independent RED is retained in its historical reports; final f186 fixture acceptance was independently established before root froze e9d297. No previous failure is silently relabeled. Existing conditional skips are not counted as coverage.
4. Android native evidence is precisely **three API28 x86_64 emulator fixture tests** executed at `0fc080e54bad0ad2789cc5d2c7fba28b753c2e17`; the 12 named input paths have zero diff to this candidate and all six original evidence hashes match. Reporter teardown is not a fourth functional test. This is not final ARM64 install, upgrade, Doze, OEM, network or power acceptance. The separate iOS CI 20-native-test/unsigned-IPA closure does not publish iOS or prove APNs/real-device delivery.
5. Publication changes only Android latest version, latest build and update notes. Both minimum supported builds remain 3; iOS latest stays 0.4.44+2213 and its platform-specific settings are unchanged. Static changes are exactly the Android direct-link/cache-buster in `download.html` and Android release JSON identity/URLs/bytes. Existing candidate/iOS sections and the five explicitly preserved production files retain captured hashes. CloudFront adds only the exact 2214 APK behavior (15→16); removing it yields the original entire DistributionConfig. The new behavior uses existing Hong Kong HTTPS origin; S3 bucket policy is unchanged. Old artifacts/aliases outside the named ARM64 transition are preserved by the existing guards.
6. Update notes state ordinary attachments have a 48MiB maximum, image decode limits can be lower, and suggest compression. They do not assert 16KiB compatibility or guaranteed background delivery. Android vendor push remains dependent on the unavailable vendor setup; this release does not declare that gap closed.
7. Runtime/orchestrator bytes exactly equal prior independently reviewed commit `91a5f9f50b6a232686b34adb72e8095954494260` (all six executable sources). Existing settings-service/CAS/audit transaction behavior is reused; no ledger, wallet, E2EE/key-recovery or authentication boundary change is part of this publication. Previously completed 30+7 preparer/executor and 6 real-PostgreSQL checks are reused on unchanged inputs, not rerun or expanded in claim.

## Local source backfill approval, separate from production CAS

After successful actual publication **and audit**, parent may write exactly the two frozen `source-backfill` targets. Immediately before writing, verify BOTH the current raw local SHA below and the current Git blob equals the captured production before SHA. Verify the staged after SHA, use a guarded exact-byte replacement, and record before/after evidence. Stop on any new drift; no blanket newline normalization or weakening of production baseline is authorized.

| Path | Required local raw SHA | Required Git/captured before SHA | Exact after SHA |
| --- | --- | --- | --- |
| frontend/download.html | f8ecee91b7bbe8640e41a172a588c5c9cba49dbaf1856b14ff0061d165e577ff | f8ecee91b7bbe8640e41a172a588c5c9cba49dbaf1856b14ff0061d165e577ff | 829a8cc49d1deef816de916d42b34b9cf3723e8ef5c2c418e77990bee1323c44 |
| frontend/downloads/android-release.json | d551fb5d6dad641cfcc2272571f758973236ec5b49ba60656457298822d83d63 | 286ae4bc798243dd6b3f9ef2b7a3205d9432ddc4c21fb5bf6d9d8b151dd96fbf | a9e0289716761f72feaf688402f79592b0a225ae1479cd1b4e0564fc433113d7 |

HTML is already raw-identical (9245 bytes, including its existing line endings). JSON local raw is 381 bytes versus captured/Git 372 bytes: exactly nine CRLF→LF bytes and strictly equal JSON. The independent check permits only this named, exact-SHA representation discrepancy. Production captured bytes and frozen plan stay unchanged. Before and after replacing the two named files, recheck the five preserved files against their own reviewed Git identities (unchanged from e9d297) and their own exact pre-write local raw SHA; retain those bytes even when local EOL differs. The existing local `admin-home.js` Git/raw SHA is `5a33f4689a1fbd7ad3eb304dbf2b7e0f70f8334491fb9e519152a06935996190`, while production captured SHA is `b804b6f98d9cf52a0f981e46049b1f8660313f57083119f8a810965f38015c27`; the local wallet cache-epoch arguments predate this candidate and must neither be deployed nor reverted by Android backfill. Production and local preserved guards deliberately retain their separate existing identities. This reviewer has not applied either source backfill.

## Accepted scope and next action

No new release blocker beyond the explicitly retained existing P1/native and missing-device limitations in the second report. Authorize the exact 11 executor operations only after its bound review validation: `preflight`, `runtime`, `upload`, `assemble`, `hk-install`, `cdn-install`, `cdn-check`, `hk-switch`, `publish`, `inspect`, `audit`. Parent must read the live baseline before mutation, execute each phase once, and stop/inspect any uncertain result. This review authorizes no worker deployment or arbitrary service change through this package.

Evidence: [independent checks](independent-evidence.json), [final raw inspection log](independent-inspection-final.log), [inspection source](inspect_exact_package.py). The original package and build remain under root's `android2214-release/final-package-e9d297-r3` and `im-reliability-release/android-arm64/run-20261011-175600-r3` artifact directories.

Completed UTC: 2026-10-11T10:25:14.670134+00:00
