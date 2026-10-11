# Android 2214 preparation — independent final review

**SPEC/domain PASS, then QUALITY PASS for preparation only. Actual release remains NOT_READY: no real final APK or final package has been supplied.** No new blocking finding remains after the two initial P1 repairs. This is not an approval to execute publication.

Reviewed immutable author chain: `b9f96f4fc69fbe226bcf8cd9e03444455eee829b` → `80954f9be3064c47d9b760501456c67bc4d37f9a` → `4341d84451d632988921fad627d237ad56000ef8` → repair `717488294e271f6c84f6a99bf85bfcd9f71e1e4d` → evidence-only `91a5f9f50b6a232686b34adb72e8095954494260`. The reviewer did not author these changes. Initial independent evidence is frozen in `d57a24f73ae4e44d91426dcc760152dc3f025da8`; [initial report](review-initial.md) preserves both RED results rather than replacing them with GREEN.

## SPEC/domain

The preparation chain keeps the required source build, conventional APK rebuild/alignment, stable signer, ARM64/package/version validation, immutable APK SHA/length, source/lock manifest and three hashed gate reports (`shared_flutter`, `native_android`, `final_apk`). Target is Android `0.4.45+2214`, package `com.liuhetong.mobile`, signer SHA-256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`. It requires these real inputs; it does not fabricate them. A gate report's hash binds the supplied report, not the truth of a handwritten assertion: the final reviewer must inspect actual build, native, shared, signing and APK verification evidence.

Executor defaults to local PLAN_ONLY and requires explicit execution plus exact package/review/source/artifact/operation bindings before transport. Fresh read-only baselines, single-attempt receipts, bounded exact-hash receivers, regular-member archive validation, a private host lock and CAS precede mutations. Unknown outcomes stop for inspection instead of replay. Unknown database commit retains the validated static state for investigation instead of automatically rolling it back. The source-backfill plan is review-only and needs its own before-hash check when later applied.

Fixed AWS account `218022113852`, distribution `E30IR8IHK6PMXZ` and CDN `d12fjr06o6tga5.cloudfront.net` are preserved. The intended CDN mutation appends only the exact new APK behavior; existing configuration, S3 policy/objects, old APKs and other ABI aliases are retained. Publication changes only `download.html`, `downloads/android-release.json` and Android version/build/notes settings. Five other static files, five iOS settings, both minimum-build values of 3, install URLs and every recorded container identity/image/restart/start time are checked. No service deployment or restart is part of these scripts.

The settings transaction uses the existing public service with advisory/row locking, CAS and audit records. Its AST is unchanged from the 2213 implementation; the six previously executed PostgreSQL proofs are reused, not rerun or added to this review's test count. The final settings file differs from the initially reviewed workspace representation only by newline normalization.

## QUALITY

Both initial blocking findings are closed:

1. **Frozen-byte reproducibility.** Final source, snapshot and evidence identities now distinguish Git bytes from original captured workspace/log bytes. All 14 captured static copies in the frozen Git commit match the original live SHA/length and recorded blob IDs; the original live baseline was not weakened. All 11 source hashes and five canonical evidence hashes match. The exact Git export now runs successfully, so preparation no longer depends on the author's uncommitted CRLF representation.
2. **Automatic static rollback.** `apply_static` reads and verifies all `before` buffers before writing, then uses those same buffers for backup and exception restoration. It does not reread a mutable backup during automatic rollback. Its existing target-equals-`after` check still protects external newer content. The corrupt-backup regression now passes; unknown database-commit handling remains unchanged.

No unrelated runtime behavior changed in the repair. The independent tests also verify unrelated-container restart rejection and actual local Python receiver handling for exact, truncated, oversized and same-length-wrong payloads, including preserving an existing output on attempted replay. These tests do not exercise live SSH/AWS/Docker infrastructure: host state is synthetic/mocked and receiver processes/files are local.

## Verification and provenance

2026-10-11, UTC+08: exact final commit exported with [export_subject.py](export_subject.py) using raw `git show` bytes; all per-file identities are in [subject-r2-inputs.json](subject-r2-inputs.json). Final author suite completed at 16:26:09 and independent suite at 16:26:11. Report finalized at 16:29. Review commands used PowerShell 7, UTF-8 without BOM and Python 3.12 UTF-8 mode.

- Initial exact `4341d844` export: **16 PASS / 11 FAIL**; final exact `91a5f9f5` export: **30 PASS / 8.90 seconds**, exit 0 ([log](frozen-git-green.txt)). Final count includes the author's three added rollback regressions.
- Independent suite: initial expanded **6 PASS / 1 FAIL**; final **7 PASS / 0.82 seconds**, exit 0 ([tests](test_independent_boundaries.py), [log](additional-green.txt)).
- Byte identity: **11 source / 14 captured static / five canonical evidence identities match**, unchanged original live baseline ([receipt](identity-green.json)).

Reproduction from this reviewer's repository, using only local files:

```powershell
py -3.12 docs/verification/artifacts/2026-10-11/android2214-independent-review/export_subject.py 91a5f9f50b6a232686b34adb72e8095954494260 subject-r2
py -3.12 -m pytest docs/verification/artifacts/2026-10-11/android2214-independent-review/subject-r2/test_package_gate.py docs/verification/artifacts/2026-10-11/android2214-independent-review/subject-r2/test_execution_gate.py docs/verification/artifacts/2026-10-11/android2214-independent-review/subject-r2/test_release_contract.py docs/verification/artifacts/2026-10-11/android2214-independent-review/subject-r2/test_static_rollback.py -q
$env:ANDROID_REVIEW_SUBJECT = (Join-Path (Get-Location) 'docs/verification/artifacts/2026-10-11/android2214-independent-review/subject-r2')
py -3.12 -m pytest docs/verification/artifacts/2026-10-11/android2214-independent-review/test_independent_boundaries.py -q --basetemp docs/verification/artifacts/2026-10-11/android2214-independent-review/tmp-green
```

Critical final Git SHA-256 identities:

| File | SHA-256 |
| --- | --- |
| package_release.py | `841f748f91881749c214833e80728b3f110758b691a634faa337ce18d34aaa12` |
| execute_release.py | `1285d349d6bedcfb3144034db7e445c1ea790ab17e59730e3f7970760bb30d51` |
| payload/delivery_2214.py | `0697a59e026c40d2ca42bf48870314f4444d1f0b86064ee5804d5dc4d89266cf` |
| payload/release_2214.py | `24275770c0948d25b30e4633c0d5301f0897393d8095af32290a8783aaeca0bf` |
| payload/settings_2214.py | `2ce834bb06ef59ce3a30e54894859f2a5f2ebb21dafa1ee4c13c260fd9741734` |
| payload/verify_production_2214.py | `827a7d714eb977917f7e783be0faf69b1fcb633bfd0c4eb661112f6bdce21f14` |

No deployment, cloud operation, live server/device inspection, APK creation or author/root file mutation was performed by this reviewer. Global verify and mobile/native/device gates are not claimed by these artifact tests. Root owns integrated shared/native/build gates; final actual package review remains separate. The next executable step is integration of the frozen preparation chain, then production of the real ARM64 APK and complete frozen gate evidence, followed by review bound to that exact package. There is no ready-to-publish artifact in this preparation review.
