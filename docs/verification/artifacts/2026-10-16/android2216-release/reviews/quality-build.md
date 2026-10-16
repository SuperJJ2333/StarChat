# Android 2216 builder — independent QUALITY/SECURITY review

CURRENT STATIC QUALITY: PASS after the binding corrections reviewed below. Three original P2 findings are retained as history and closed by the follow-up review. No signing-secret disclosure, signer rotation, product/security weakening, or unauthorized remote mutation found in the inspected builder/helpers. FINAL ARTIFACT QUALITY: PASS for conventional build, fixed-signature and evidence-binding scope, with the unchanged libcrypto P1 limitation explicitly retained. The completed-artifact review below supersedes earlier pending checkpoints; this is not 16KiB-device or ARM64-phone acceptance.

## Scope and identity

Specification review `reviews/spec-build.md` was read first and reports SCRIPT SPEC PASS. Reviewed `build-release.ps1`, `freeze_mobile_input.py`, `collect_gates.py`, and named dependencies necessary to verify signing, registrant correction, release payload and rebuild semantics. Read the current Android packaging runbook. No builds, suites, signing, source changes, index changes or remote writes were performed. Only this review document is owned.

At the read checkpoint, `arm64-final/steps.tsv` contains successful steps through decode; no final artifact receipt is assumed. Initial freeze-input.log binds HEAD `35f59abbb6bdaa0fe6c826aaff904130bb6dea76`, 2113 mobile files and manifest SHA `b07dfdc5a4632f338f27562ea32dd45e280c01fe4da7e4313be1bdb2d98a301f`. Earlier 544b61b6 host/native-main evidence retains its stated source and device limits.

## Findings

### Q1 — P2: reuse comparison is not bound to the artifact source

`collect_gates.py:20–21,24–38,41` compares each reused evidence commit against live HEAD, then attaches the build receipt's unrelated source_commit to the resulting PASS. The collector checks the manifest's file hash but never checks its embedded commit against that receipt or the comparison endpoint. Therefore a valid older arm64-final receipt/APK can receive tests from a newer HEAD with the same lockfile despite changed mobile source. This is a concrete missing relationship, not evidence that the current 35f59abb build is already mismatched.

Use the build receipt commit as the comparison endpoint; verify its agreement with the frozen manifest and the initial freeze-input.log identity. Require intended release target lib/main.dart and the expected version/package/ABI before generating final gate metadata. `build-release.ps1:72` also supplies the manifest's freshly recomputed hash to verification, rather than retaining the prebuild hash; binding the collector to the already recorded initial freeze-input.log hash closes this audit gap for the current build without rerunning it. A later builder revision can retain the original digest directly.

### Q2 — P2: native report can be stale while receiving the current APK binding

`collect_gates.py:53–57` reads native-static.json but checks only matrix_symbols against the old report before emitting final_apk PASS and saying inspector exit1 is retained. The native schema includes `source.sha256`, `final.sha256`, library inventories and explicit ELF failures, none of which is currently checked. Copying an earlier native report with identical Matrix symbols would satisfy this code and falsely label that report as current-artifact evidence. Separately computed native-library equality is useful and limits actual native drift, but does not authenticate the claimed fresh report.

Require report source/final SHA256 to match the actual APKs, check its native inventory against the computed inventory, and retain the real inspector exit status/log with the named known failure set. The existing libcrypto LOAD/RELRO limitation must remain a limitation; do not require or claim runtime 16KiB support. No new device run is requested by this finding.

### Q3 — P2: truncated step evidence passes the completeness check

`collect_gates.py:28–29` applies all(exit_code == 0) without validating the expected step names or uniqueness; a header-only or truncated steps.tsv passes. Later reading several logs does not prove every required step executed, including align, sign, rebuilt-manifest and verify-decode. Require the complete expected ordered sequence (or exact unique set) from the builder, with zero exits, before creating any PASS gate files. Prefer completing validation before creating OUT so a failed late validation does not leave a partially generated gate directory that prevents a clean retry.

## Positive checks and limits

The fixed signing helper validates the one expected RSA-3072 certificate and v2/v3 signatures, uses DPAPI and a short-lived per-process password environment variable, suppresses sensitive tool diagnostics, validates ordinary nonlinked paths and atomically publishes the signed result. The wrapper does not generate a key or log a password. Known public endpoints and synthetic fixture data are not secrets.

The builder uses a new run directory, rejects dirty mobile inputs, locks offline dependencies, performs source build and full Apktool rebuild, aligns before signing, validates actual source/final ABI payloads, requires nondebuggable version/package identity, compares native/assets by SHA and exact smali/manifest semantics under narrow normalization. No arbitrary padding or semantic patching was introduced. The generated registrant correction is bounded to a known ignored dev-only block, and its log preserves before/after hashes; it is not part of the nonignored mobile manifest, so keep this distinct evidence.

Known environmental and platform limits remain explicit: shared host 6038 PASS/9 SKIP is not global verify.ps1 success; matching-source Debug API28 x86_64 emulator results are not ARM64 Release installation or broad ROM/weak-network/performance acceptance; zipalign -P16 is not ELF/device 16KiB support. The known libcrypto native-inspector exit1 must not disappear into a pristine-gate claim.

Final artifact review is required after output: exact final SHA/size, receipt and complete steps, fixed signer verification, alignment, release identity/ABI/assets, semantic rebuild result, frozen input identity, current native report and corrected gate bindings. Existing tests can be reused under their proven unchanged closure; no duplicate full suite is requested.

Reviewed script SHA-256 (2026-10-16T10:42:23.4821658+08:00):

- build-release.ps1: cc4023aacfd26a26a0a91f8f9b37a1d9f7fecd2152f0a80bb89db6d02ca75796
- freeze_mobile_input.py: a75a813c144f0729356a04e3fbb3cd9e9d520775420add08151f38599bba4cc9
- collect_gates.py: c908b951f7ff5e82e22796eab332796323fe6bee8c7c9028ad9e17a55365520e

## Follow-up review — binding corrections

Root corrected collect_gates.py while the original build continued. Static re-review confirms Q1, Q2 and Q3's blocking integrity issues are addressed: comparisons now target the artifact commit; receipt, embedded manifest and initial freeze record must agree; intended app identity/target is required; all 20 ordered steps must be present exactly; native source/final APK SHA and size must match; actual inspector exit1, retained known libcrypto flag, unchanged LOAD/RELRO observations and no stored-ZIP alignment failures are required.

STATIC QUALITY after these corrections: PASS for the reviewed builder/evidence logic. Two nonblocking evidence-hygiene follow-ups were communicated: include the already checked native-inspection-receipt.json in final_apk evidence hashes, and defer all gate-directory writes until the last validation to avoid leaving partial PASS files on a later rejection. Neither requires a new build or full suite. No current source/runtime defect was inferred from the earlier binding deficiencies.

The actual native-static report now exists and its inspector receipt records exit1; the earlier incomplete inspection due to the wrong baseline is retained separately rather than treated as a pass. At this follow-up read, build steps were successful through verify-decode, with rebuild-verification still pending. FINAL ARTIFACT remains PENDING. This static verdict is not final artifact acceptance or publication approval. No negative fixture runner was needed: the corrected predicates were inspected directly, and the real artifact checks will exercise their positive path once the original build finishes.

Follow-up collect_gates.py SHA-256: c908b951f7ff5e82e22796eab332796323fe6bee8c7c9028ad9e17a55365520e; reviewed 2026-10-16T10:43:03.2837189+08:00.




## Completed artifact QUALITY/SECURITY verdict

PASS for this exact conventional build/signature/evidence-binding scope. No new actionable quality/security finding remains in the reviewed builder or collector. The existing libcrypto P1 LOAD-alignment risk remains open; this verdict neither fixes nor waives it. Publication preparation is a separate review.

Read the completed SPEC verdict and actual receipt, signature, identity and rebuild results. Independently recomputed final.apk SHA-256 `db914f66229cffa79825954200845ac841fd10486c77fb8ecce94dbef7b41039` and size **73,262,170 bytes**; both match the receipt and gate binding. Independently verified all three child gate hashes and 21 referenced evidence SHA/size pairs. All 20 expected builder steps are present and exit zero. No build, test suite, collector rerun or signing rerun was performed.

The receipt identifies HEAD `35f59abbb6bdaa0fe6c826aaff904130bb6dea76`, lib/main.dart, standard ARM64 Release, version 0.4.47+2216 and package com.liuhetong.mobile. Actual aapt log confirms package/version/arm64 and no application-debuggable marker. Signature log confirms one expected RSA-3072 signer `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff` and successful v2/v3 verification. Rebuild result binds the same APK and preserves all 25,414 classes, 168,863 methods, six-DEX inventory, manifest semantics and 274 native/asset entries under the reviewed normalization. Frozen-input identity and the original prebuild digest agree.

Final collector SHA-256 is `d54cecde90140af6c6895b45ceae86b09251a2720c70fb81c45bff54e00d2fb7`. It now buffers gate output until all checks finish and includes native-inspection-receipt.json in the hashed evidence, resolving both nonblocking follow-ups. The real native report binds the final APK and identifies only lib/arm64-v8a/libcrypto.so in LOAD failures; static_16k_checks_pass=false, runtime_16k_verified=false and inspector exit1 remain recorded. Relative to the prior SHA-bound 2215 APK, native libraries other than libapp.so are unchanged. No new Android 16KiB compatibility claim is supported.

The existing plugin compiler/deprecation diagnostics, global verify.ps1 environment limitation, and absence of ARM64 real-phone/broad-ROM/weak-network/release-performance coverage remain visible. Shared 6038 PASS/9 SKIP and matching-source Debug API28 runtime evidence retain their exact stated reuse scope. This report does not relabel those results as native ARM64 Release testing or a warning-free build.

Final artifact review completed: 2026-10-16T10:48:28.8205182+08:00.

