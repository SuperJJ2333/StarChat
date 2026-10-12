# Android 2215 actual release — independent specification/domain review

Result: PASS for the precisely bound, user-authorized Android media-startup repair publication. This review precedes the quality/security review. It does not certify universal device compatibility, production execution, or completion of the original nine-domain performance assessment.

## Frozen identity

| Item | Exact identity |
| --- | --- |
| Package | `android2215-release/publication-final-2215-20261012-r2` |
| Freeze SHA256 | `d08e5c8aa80af4429c6dd8d8a953279d907ceb4c4b281f684998036d1a9a558b` |
| Operation | `mediafix-20261012-2215` |
| Source commit | `9990ca6e752271d2a37610bc3be37e68f80a14c0` |
| 2,102-file source manifest | `fb3e8fd4996747f4f81ebf9b6f39d93dcf430be9829fe3ee2751c1a7d2a4e42d` |
| pubspec.lock | `a43833c8e7c3d6faa93d21babdc61dfe4b3563c7ac00912006f26daa8e0ecc5d` |
| Actual final ARM64 APK | `4b43bd1ca655918b9754183c1713ed5eb6e864379a2e2ccc6bd861195578b6a6`, 73,262,170 bytes |
| Runtime archive | `2926e0b4c1ced432d97ca37e20a872f983c79f545e4b7d86babb06ebf4b27248`, 50,856 bytes |
| Public identity | com.liuhetong.mobile, 0.4.46/build2215, ARM64, minSDK24/targetSDK36, nondebug |

## Product behavior and boundaries

The previously independently reviewed AppHome change orders binding of the current media-outbox generation before opening that generation. The old ordering could deterministically leave the outbox inactive and reject both image and video sends. It retains generation/disposal/account-change checks and fail-closed handling rather than suppressing them. The prior focused independent review is commit `0a2a127d`; its 14 passing tests used desktop SQLite/native-codec doubles and were never claimed as phone SQLCipher execution. No further behavior change was introduced during packaging.

The actual normal-main debug regression adds runtime evidence: old 2214 reproduced failed gallery image/video sends and inactive queue; fixed 2215 reported active queue, encrypted `m.image` and `m.video` events with `EventStatus.synced` and server IDs. The original image viewer displayed the synthetic image. Video screenshots show actual frames/time progressing from 0 to 2 seconds of a 3-second file; the filename containing “completed” is not proof of full playback completion. A real force-stop/start receipt has exit0 and observed PID10821 to PID11824, with the video synced after restart. Exact operation wall timestamps were not persisted and remain unknown.

These observations are from API28/Android9 x86_64 emulator5556, normal `lib/main.dart`, the same fixed signing identity, an update preserving UID10090, and one self-only encrypted room with zero invitees. Real gallery/UI, upload and server event sync were used; isolated-room creation/navigation and state reading used a debug VM helper. No other user received test messages, and no E2EE guard was bypassed. This is not a second-user delivery test, a real ARM64 phone test, weak-network testing, a device reboot, or an all-ROM result. A later unrelated foreground-app screenshot was discarded and contributes no evidence.

References: [media preliminary observation](media-preliminary.json), [receipt supplement](media-runtime-supplement-review.json), [shared-input and restart closure](shared-input-reuse-and-restart.json). The preliminary pending restart item is historical; the supplement closes only that item.

## Exact verification reuse

The final shared run recorded 5,965 Flutter passes, 9 skips, 0 failures; analyze reported no issues. Final privacy/boundary tests recorded 401 passes, 1 skip, 0 failures. The earlier 396/5/1 boundary run remains retained, with four fixture-directory errors and a CI-version-literal error followed by the corrected run. Skip reasons absent from the logs are not invented.

Reuse is based on content, not a claim that all raw files or environments are identical: 2,096 of 2,102 manifest entries are raw-equal; six inspected files differ only by exact CRLF/LF representation. They are MediaStoragePolicy.kt, NoFollowPosix.java, PrivacyInfo.xcprivacy, app_config.dart, app_home_media_outbox_startup_test.dart and moment_video_test.dart. Generated package_config bytes match. Plugin metadata differs only in its creation time and six workspace-prefix paths; the two corresponding complete plugin inventories (105 and 29 files) match. The source commit transition before final packaging contains no mobile Git behavior change. Full comparisons and bound raw hashes are in the shared-input receipt.

The whole `scripts/verify.ps1` run exited1 on missing `.env` at init_matrix render. Its completed prefix is usable evidence; later infrastructure/API/worker gates were not executed and are not represented as passing. This scoped release relies on the completed mobile, boundary, packaging and guarded publication gates; it does not convert the whole verifier into PASS.

## Native and packaging scope

Actual source build, conventional rebuild, alignment and stable signing produced the final APK; all 28 build steps recorded exit0. Actual original semantic verification covered 25,414 classes, 168,863 methods, six DEX files, 274 assets/native entries and manifest semantics. Independent final checks confirm signature, alignment, all 274 source/final ZIP entry bytes, and the 57 compiled MainActivity/call classes plus whole bounded manifest closure. The historical native closure has 400 source inputs; it is a static reuse boundary, not new runtime media acceptance.

The 14-library independent native report is now fully embedded in the r2 final gate with SHA256 `168bae7b8bd81be9969eba62e63a91522f4fa753f3d17d75c8b77e6b094c4b27`. Its 16KiB static result remains false/exit1 and runtime verification remains false. The existing libcrypto 4KiB alignment risk is explicitly retained; no 16KiB success or actual final ARM64-phone result is claimed. See [native review](native/README.md).

## Publication domain

All eight execution/payload programs are exact bytes from already independently reviewed `c1b1ccd777d7ef11a1a1af956547b43bbf89d573` (32 actual preparation tests passed; own review commit `2beac30f`). The actual payload changes only Android download HTML, Android release metadata, the three Android version/build/notes settings and the new 2215 CDN route. Existing 16 CDN behaviors and bucket-policy bytes are retained. iOS settings/download manifest, minimum supported build3, wallet/ledger modules, credentials and product services are not written by this package. A financial domain decision is neither made nor derived from Matrix.

The two source-backfill targets are `frontend/download.html` and `frontend/downloads/android-release.json`. Their before bytes currently equal the captured production snapshot and frozen source Git bytes; after bytes are precisely staged. Only the APK link/redirect build in HTML and six Android metadata fields change. No CRLF exception is needed for these targets. [Source-backfill review](source-backfill-review.json) binds the exact unchanged plan; [r2 delta](publication-r2-delta-review.json) proves it is byte-identical in the approved r2 package.

The b93b package was withheld because its final gate did not yet bind the completed native report. R2 closes that documentation/evidence gap without changing artifact or payload. Its 38 frozen members and all 24 safe regular tar members pass actual local validation. The regenerated archive changes gzip time, tar times/PAX times and corresponding header checksums only; all member payload bytes and other parsed metadata match. The new archive hash, not the old one, is authorized.

## Remaining acceptance gaps

The original nine areas are not all closed by this hotfix: OEM push remains unavailable per the user's app-review constraint; background survival/power/ROM matrices, notification sound/permission matrices, delivery latency percentiles and second-user receipt, weak-network frame/ANR data, OOM/long-run memory data, disk/cache endurance, multi-region failure/SLO exercises, directory migration endurance and cold/warm/hot-start benchmarks still require separate measurement. iOS signing/distribution and actual iOS device media regression are outside this Android package. These are recorded gaps, not inferred passes. The unchanged P1 16KiB issue requires its own repair and real device validation.
