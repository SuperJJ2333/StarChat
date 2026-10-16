# Android 2216 publication — independent specification/domain review

Verdict: **PASS** for the frozen publication package and scoped execution design. No actionable specification defect found. This is a pre-execution review, not a claim that production publication, popup display, or post-publication acceptance has occurred. Quality/security review remains a separate gate.

## Reviewed identity

Reviewed imported backend 9d2b3127 / integration e6487ad3, publication/adaptation.diff, actual publication-final-2216-20261016 package, executor/runtime/source-backfill, validation logs and PostgreSQL evidence closure. Independently recomputed all 38 frozen file hashes: no mismatch. No tests, builds, remote commands, or source/index mutations were performed by this reviewer.

| Input | SHA-256 / identity |
| --- | --- |
| freeze-manifest.json | `5df015a69df956450a6e1d8ec9c728324fce9c3bfa1be2863f18385aa3d551a6` |
| Final APK, 73,262,170 bytes | `db914f66229cffa79825954200845ac841fd10486c77fb8ecce94dbef7b41039` |
| Mobile source commit | `35f59abbb6bdaa0fe6c826aaff904130bb6dea76` |
| Mobile source manifest | `b07dfdc5a4632f338f27562ea32dd45e280c01fe4da7e4313be1bdb2d98a301f` |
| runtime-2216.tar.gz, 50,955 bytes | `7d7812617eb31db6b949a7f7ab3fb1e16f72508ef8896d72b9a503f8da055479` |
| orchestrator/execute_release.py | `bb7012c03ac961a7ad992a5e1a74f76414eecca7f883499f4798ffe00397feb3` |
| orchestrator/package_release.py | `7b54123738db300bfc519fe53134e8d209b38665891bd70772eb33588586e699` |
| runtime/prepared-2216/release.json | `1201983bd54afca2b39b4bc6fa202c3acd424eb6fa123a54d90e7ad3f44c31ea` |
| runtime/release_2216.py | `9e7d0afc02268b251327c9c27db22f4c465fd607103df7c9a1c4b2e1eff13ebd` |
| runtime/delivery_2216.py | `c8e0d02748cc0a38653a0cb0068d74ab5014e2ee764e6dc9fde3c16ad860e001` |
| runtime/settings_2216.py | `da42de0b0b249624fd657f0f67422c9eaea12eab0350eb33a449250b09a1a2ae` |
| runtime/verify_production_2216.py | `827a7d714eb977917f7e783be0faf69b1fcb633bfd0c4eb661112f6bdce21f14` |
| source-backfill/plan.json | `b9a1b989b1a02d733a5a0fe73384a10ecab1a99e98c252bc60c94ba764541d30` |

## Specification and domain checks

- The exact standard ARM64 artifact is com.liuhetong.mobile 0.4.47+2216, signed by existing 75b31 identity. This agrees with spec-build.md; the known unchanged libcrypto ELF 16 KiB limitation and unavailable ARM64 physical-device acceptance remain limitations, not newly asserted passes.
- Android settings change only latest version, latest build, and update notes. Both minimum versions remain 3; iOS latest remains 0.4.46+2215, with its notes and URL unchanged. This implements an ordinary update offer rather than raising the compulsory-update threshold. Actual client popup acceptance remains root-owned.
- Fresh recorded baseline is HK 2026-10-16 02:36:33 UTC / SG 02:36:39 UTC. Executor compares settings, schema, selected settings dependencies, permanent guards, seven static files, aliases/artifacts, CDN configuration, and all 35 service runtime identities before mutation. No service rebuild/restart, migration, authentication, wallet, or E2EE mutation is included.
- execute_release.py:31–79 binds frozen package bytes, archive inventory, source evidence, operation identity and both review reports. Lines 104–117 and 249–252 require a fresh remote baseline; old snapshots alone do not authorize proceeding after drift.
- delivery_2216.py:65–101 creates the new versioned APK without overwriting an existing different artifact, preserves the prior APK, and changes only the ARM64 alias after identity/readiness checks. CloudFront adds the exact new APK path to the existing HK origin while preserving prior rules and bucket policy. Its update uses current ETag / If-Match; it does not upload an S3 object or broaden policy.
- execute_release.py:152–158, 229–293 enforce immutable upload/assembly → HK install → CloudFront install → confirmed Deployed and HEAD/CORS readiness → alias → publication. CDN readiness is rechecked before alias switching and publication. Public checks use HEAD plus small metadata, consistent with the runbook's prohibition on redundant whole-APK public downloads.
- release_2216.py:200–238, 352–381 changes only download.html and downloads/android-release.json under a host lock, with exact before/after hashes, private raw backups, per-file CAS and verification. Pre-database failure permits restoration only from verified original bytes against the expected changed bytes. A database commit/readback ambiguity records outcome-unknown and stops without guessing rollback.
- settings_2216.py uses the public SettingsService, PostgreSQL advisory/row locks and an outer transaction; all ten values are checked, only the three Android values are written, and exactly three trace-bound before/after audit events are required. verify_production_2216.py checks Android/iOS route projections and audit identity. It is not evidence that an external unauthenticated HTTP rejection check has already run.
- Executor uses exclusive in-flight state and refuses replay of mutation after unknown outcome or prior phase receipts. Read-only inspection/audit remain available. No cross-host atomicity is claimed: artifact, CDN, alias, files and database are distinct checked phases.

## Evidence reuse and limits

Read the recorded 35-test PASS log and prior RED evidence; these are local boundary tests with simulated package/transport cases, not live production publication. PostgreSQL closure retains the earlier six passing PostgreSQL tests because the transaction body and normalized settings module/test logic are unchanged except release constants, notes and trace identity. The four relevant live settings/audit/database dependency hashes match the prior tested source, and fresh preflight rejects their drift. The current API image differs from the historical image; this report does not claim whole-image equivalence or a new PostgreSQL run. Existing unchanged mobile host/native evidence is reused; no broad suite was repeated.

## Local source-backfill exception — accepted scoped reconciliation

The frozen runtime is based on live iOS 2215 and correctly preserves it. The current repository still contains some earlier iOS 2213 metadata, so the source-backfill plan's live before-hashes must not be represented as matching current local files. Independently compared normalized text and raw hashes:

- frontend/download.html current `eeb75215b8bcea683202923ff27f5ce5c130e139a94d8a286c90f6dd82576dd4`; live baseline `df2ecae1e25561b83a339478bfd80dc2d921f3c6e5964b26f1e5dc8849211491`. Text differences are the iOS version/size label and IPA URL.
- frontend/downloads/ios/manifest.plist current `059fd04cc113d88e86d91c123715526234d8624342adf94c61d2acfdbea43bf4`; live `f0c9014caf807a8a862f7fbfd64d0d14e209905879ac8b29f0c311c9c915ee16`. Text differences are IPA URL and build number.
- frontend/src/admin-home.js current `5a33f4689a1fbd7ad3eb304dbf2b7e0f70f8334491fb9e519152a06935996190`. In addition to two stale iOS labels at lines 173/175, local line 102 contains expectedCacheEpoch/getCacheEpoch wallet authentication guards absent from the live snapshot. **Do not copy the live admin-home.js over this file.** Preserve those guards and change only the two version-label literals.
- download-network-selector.js and download-network.js have identical normalized text; raw differences are line endings. Leave them unchanged. The plan's preserved hashes describe live production, not permission to overwrite divergent local security code.

Root's proposed local-only reconciliation is within scope: capture the exact local before-hashes and diff, reconcile the already-approved live iOS metadata without any remote iOS mutation, preserve local authentication additions, then apply the two reviewed Android backfill outputs after publication/audit. Android download.html target hash is `a79c2eb04672964afa74b5be7712f79fe6340bb14d7f594315e24f85ae824dea`; android-release.json target is `525f36106048d8ed2c8a2bcff4d612350fc3b407fcfdfc1f0b49c44277bb0443`. This exception does not change runtime package bytes and does not require refreezing that package. Final source reconciliation still needs root's exact diff/hash acceptance before commit.

Reviewed against mobile delivery, APK rebuild, admin production and release metadata runbooks, using the starchat-admin-production skill. The proposed operation `experience-20261016-2216` must retain its exact review binding and fresh preflight. Root owns execution, live postconditions, audit/popup checks and final source backfill; none are marked completed here.
