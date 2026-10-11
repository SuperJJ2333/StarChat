# Android 2214 release preparation checkpoint — NOT READY TO DEPLOY

Owner: review_r1_r2 (handoff from review_media_android at 80954f9b). Parent authorization is limited here to preparation, read-only live inspection and isolated tests. No upload, cloud resource mutation, publication, service restart or production setting write has been run. Base: 218d2c73eb41f4f3f5258e1232840d82c27d4211; branch codex/android2214-release. All owned files are below this artifact directory. Existing scripts, frontend, clients and parent checkout are untouched.

Target: Android 0.4.45+2214, com.liuhetong.mobile, ARM64, fixed signer 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff. Final APK SHA/bytes are unknown and have no defaults. No production release.json or staged registry with invented values exists.

## Confirmed minimal reuse

Reuse the 2026-10-09 Android 2213 release modules from primary docs/verification/artifacts/2026-10-09/android2213-release/publish-prep. The new payload copies explicitly change individual version fields; no broad build-number replacement touches account/ARN/resource identities. Keep shared locks, exact state classification, immutable file install, static compare-and-swap, private backups, PostgreSQL transaction CAS via public SettingService and audited three-key writes. Settings transaction body is unchanged; six real local PostgreSQL proofs ran against this checkout's settings implementation.

Read-only snapshots taken 2026-10-11 07:40 UTC confirm both platforms 0.4.44+2213, both minima 3, schema0095, 35 running containers, old immutable Android APK 08a74481…/73139489 bytes, target APK absent. SG CloudFront is Deployed with 15 behaviors, ETag E3DWYIK6Y9EEQB. These are observed baselines, not future publication authorization or a guarantee they will remain current.

- Only download.html's exact Android APK anchor/cache tag and downloads/android-release.json change. Existing iOS2213 IPA/manifest/homepage/selection scripts are preserved byte-for-byte.
- Only Android version/build/notes change; iOS five settings, minimum3 and installation URLs remain exact. Minimum stays 3, so this is a normal skippable update for supported clients. Actual phone popup is not tested here.
- Append only downloads/ChatFlow-0.4.45-build2214-arm64.apk as one exact HK-origin CloudFront behavior. Preserve the first 15 behaviors and every other config field. Account218022113852, distributionE30IR8IHK6PMXZ, bucket, assumed-role and host identity stay fixed. S3 bucket policy has no change and no object upload is added.
- Preserve old immutable APKs and other ABI aliases. A completed new alias requires the exact new artifact. Preserve all35 running container ID/image/restart/start identities; never roll back services to satisfy a stale snapshot.
- Unknown static/settings/CloudFront states stop. Static rollback only touches this operation's exact written hashes. A database commit timeout retains validated pages and writes outcome-unknown; no blind replay or automatic rollback follows an uncertain commit.
- Draft Android notes explicitly describe the current ordinary attachment48MiB ceiling, lower image limit and compression retry. Parent may refine exact wording before final freeze.

## Checkpoint evidence

- contracts-red.log: old2213 logic failed target2214 assertion and rejected fresh baseline in three guards (one assertion failure, three ValueErrors). This establishes adaptation was required.
- contracts-green.log: 9 offline contracts PASS. Real temporary files cover immutable install/CAS/old-object retention. Cloud/SSH are not called by these tests; transport-only doubles cover unknown commit and cloud identity rejection.
- postgres.log: 6 PASS in8.16s using pinned local PostgreSQL16.9 fixture, unique synthetic schemas, loopback port, automatic own-container removal. Covers three audited keys, iOS drift refusal, failed readback transaction rollback, reused trace rejection, concurrent admin set/set_many waiting. No production database connection.
- package-red.log: 3 expected test-first FAIL because final-artifact package gate is not implemented yet. This is an incomplete checkpoint, not an all-green final handoff.

## Completed preparation code; final artifact still required

`package_release.py` now requires the actual final APK, builder receipt, successful steps, mobile source manifest and three source/artifact-bound gate reports. It rehashes every listed source input and the lock; gate evidence is a regular, non-symlink relative file with an exact SHA. The gate reports attest the actual build; the package validator does not itself rebuild/sign the APK or treat the synthetic test fixture as a real binary. Source commit comes from the verified builder/gate receipts; later evidence-only HEAD commits are allowed while all source manifest inputs must remain exact.

The output is fresh and atomically published locally only after validation. It contains the exact APK, receipts/evidence, frozen orchestrator source, runtime archive, staged targets and `source-backfill/plan.json`. Backfill contains only `frontend/download.html` and `frontend/downloads/android-release.json`, with exact live before/after hashes and the five preserved files. Parent must compare local source before hashes and stop on drift; the preparation tool never writes a repository frontend. Both local bucket-policy files retain identical bytes, and no cloud policy write exists.

`execute_release.py` defaults to a local plan. Explicit execution additionally requires both review report hashes, exact package/orchestrator/artifact/source bindings, a unique operation ID and allowed operations. The intended sequence is `runtime` (fresh read-only HK/SG baseline, exclusive private stages, archive install), `upload`, `assemble`, `hk-install`, `cdn-install`, `cdn-check` until Deployed, `hk-switch`, `publish`, `audit`. Every public alias/publication action obtains a fresh CDN Deployed/HEAD/CORS result; an old receipt does not substitute. HK public actions repeat service/other-ABI preservation. Payloads keep shared host lock, CAS, immutable APK install, 0700 backups and audited SettingService transaction semantics. Local operation receipts cannot be overwritten or replayed; a transport/commit exception during mutation records `outcome-unknown.json` and blocks further mutation. `inspect` and `audit` remain read-only after an uncertain publication. A process killed before cleanup leaves an exclusive inflight marker requiring manual inspection.

No polling loop, implicit retry, global version replacement, service command, S3 object upload or bucket-policy modification is added. The runtime receiver and extracted members are exclusive, bounded by declared byte count, SHA-checked and restricted to regular relative members. SSH host keys and HTTPS validation remain enabled. Remote execution itself has not been exercised by this preparation task.

## New evidence and next step

- `package-takeover-red.log`: reproduced the three missing-package failures before implementation.
- `execution-red.log`: seven missing-execution failures, seven already-passing cases. Five passing package tests were imported a second time by that initial fixture; this historical count is not presented as unique coverage.
- `package-execution-first-green.log`: 19 executions including the five duplicated imported tests; retained as intermediate evidence only.
- `preparation-green.log`: final single run **27 distinct tests PASS** (18 package/execution plus nine inherited contracts). Includes actual local streamed file receipt/archive extraction. All SSH/AWS/production operations are transport doubles or uncalled. Negative tests cover absent/drifting APK/gates/reviews, wrong source/lock/signer, unsafe paths, phase order, live CDN pending, baseline drift, and uncertain mutation with readonly inspection.
- `postgres.log`: reuse the existing six real PostgreSQL proofs because `payload/settings_2214.py` is byte-unchanged. No claim that new transport doubles validate PostgreSQL or cloud behavior.
- `usage.md`: exact required input/review schemas and parameterized local command sequence. It deliberately supplies no final APK identity or review approval.

Next executable step: root performs SPEC/domain then quality/security review of this preparation commit. After the root-owned real build/native/shared gates complete, supply their exact receipts and run the local package command. Review the resulting freeze SHA and staged two-file source backfill before separately authorizing any publication. Final APK SHA/bytes remain unknown; no final production `release.json`, package freeze or approval has been created. Existing R7b/R8 approved plan and mobile/production/release-metadata runbooks remain authoritative. Full source/native/build gates are root-owned and are not duplicated by artifact-only preparation.
