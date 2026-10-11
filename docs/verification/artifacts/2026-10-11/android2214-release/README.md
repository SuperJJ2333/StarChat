# Android 2214 release preparation checkpoint — NOT READY TO DEPLOY

Owner: review_media_android. Parent authorization is limited here to preparation, read-only live inspection and isolated tests. No upload, cloud resource mutation, publication, service restart or production setting write has been run. Base: 218d2c73eb41f4f3f5258e1232840d82c27d4211; branch codex/android2214-release. All owned files are below this artifact directory. Existing scripts, frontend, clients and parent checkout are untouched.

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

## Remaining executable work

1. Complete package_release.py with required final APK/receipt/steps plus source-bound shared Flutter, native Android and final APK gate evidence; refuse missing/zero/mismatched SHA/bytes/signer/source/lock, unsuccessful steps or pending evidence. test_package_gate.py is the current RED specification.
2. Finish bounded execute_release.py orchestration with exact runtime/archive hashes, explicit review binding, unique private stages, read-only final baseline repeat and no default production invocation. Reuse2213 upload/assembly/HK immutable install/CF deployed+HEAD+CORS/alias/static+settings/audit order. Do not rerun full public APK downloads.
3. Generate source backfill payload for parent review only after final artifact identity exists. Do not edit root/frontend directly from this task. Freeze all runtime and staged file hashes.
4. Independently review SPEC/domain then quality/security; root binds final artifact and owns publication. Revalidate live baseline before any write; unexpected drift stops rather than silently re-freezing or rolling back someone else's change.

Parent prioritized an independently reproduced shared cache-object cancellation regression after this checkpoint, so work returns to the separate cache tree. This checkpoint has no final APK, no approved final payload, no execute wrapper and no publication claim. Existing R7b/R8 approved plan and mobile/production/release-metadata runbooks remain authoritative. Full source/native/build gates are parent-owned and not duplicated here.
