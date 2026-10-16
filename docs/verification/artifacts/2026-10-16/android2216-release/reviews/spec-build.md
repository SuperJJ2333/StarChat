# Android 2216 release build — independent specification/domain review

SCRIPT SPEC: PASS. No actionable missing build-pipeline requirement found in the inspected builder and invoked helpers.
FINAL ARTIFACT SPEC: PASS for the exact completed ARM64 Release artifact below, with the existing libcrypto 16KiB failure and missing ARM64-phone acceptance explicitly retained. This is not a blanket native compatibility PASS or approval of the separate publication transaction.

## Authority and scope

Latest user authorization is Android 0.4.47+2216 publication plus an ordinary update popup. This review covers the release builder, production artifact identity and meaningful build gates only. Android-only metadata/publication and audit preparation are reviewed separately after their freeze. iOS and minimum supported build must remain unchanged; no new financial/authentication/storage authority is introduced by this build.

Read android-apk-rebuild.md, mobile-delivery-workflow.md, current-state and the Android release task record. Reviewed build-release.ps1 and its exact signer, ABI checker, asset checker, registrant correction, input freezer and rebuild semantic checker. No build, test, remote write, source edit or subagent was executed.

## Required pipeline present

- build-release.ps1:31–34 requires clean committed mobile source and version 0.4.47+2216. Lines 48–51 restore locked offline pub inputs, freeze source/generated dependency inputs, bound correction to the ignored integration-test registrant block, then build standard Release android-arm64 without split-per-ABI version-code rewriting. All three prescribed HTTPS service defines are preserved; intended target is lib/main.dart.
- Lines 55–60 verify the source release ZIP and declared Flutter assets, capture its binary manifest, then perform the conventional full Apktool 2.12.1 decode/rebuild with this run's distinct output/framework directories.
- Lines 61–65 use build-tools 36.0.0 zipalign -P 16 -f 4 before signing, existing protected identity, apksigner verification and post-sign alignment checking. The signing helper requires exactly the existing 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff RSA-3072 identity and successful v2/v3 verification. It does not create a replacement key or expose the password in tool output.
- Lines 66–71 require final com.liuhetong.mobile / 2216 / 0.4.47, non-debuggable and arm64-v8a. verify_android_release.py checks the actual ABI inventory for source and final, requires libapp.so/libflutter.so and rejects a debug kernel. This is not a filename-only ABI check.
- The asset helper checks actual manifest memberships, required icon fonts, declared Flutter assets against source SHA and source-bound remote emoji manifest/catalog identities. Remote animated WebP exclusions are validated by the existing trust manifest rather than silently treating missing bundled animations as complete local assets.
- Lines 72–76 verify frozen inputs, compare binary manifest semantics and fully redecode the signed APK. verify_rebuild.py requires matching DEX/class/method inventories and exact smali except narrowly typed static defaults; native/Flutter asset bytes must match source APK SHA inventory. Final receipt is only written after every Step returns zero. Final signed bytes are not recompressed afterward.
- The only generated-code correction is the byte-exact dev IntegrationTestPlugin registration block; helper checks ignored/untracked ownership and unchanged remainder. Actual correction log records known block removal and outside_block_bytes_preserved=true.

## Reuse and fresh evidence boundary

A read-only git diff of apps/mobile_flutter between 544b61b6 and 35f59abb was empty. The final shared 6038 PASS / 9 SKIP / 0 FAIL result and associated analysis from source 544b61b6 therefore remain relevant without a repeated full Flutter suite. The earlier native five-case result and real main Debug preserved-data/media/autoplay evidence retain their stated closure and limitations; none is an ARM64 Release device result.

The actual new artifact must freshly pass the build-time signature/alignment/manifest/ABI/asset/rebuild checks. The initial frozen manifest records 2113 files, HEAD 35f59abbb6bdaa0fe6c826aaff904130bb6dea76 and SHA b07dfdc5a4632f338f27562ea32dd45e280c01fe4da7e4313be1bdb2d98a301f. This is evidence of inputs, not completed output.

## Initial pending checks (subsequently resolved/bounded below)

1. Final receipt plus zero exit codes through rebuild-verification, exact final APK SHA/size, matching final identity/signature/release-payload/assets and semantic-comparison results.
2. Separate final native ELF alignment evidence, or byte-identical native library hashes against an explicitly recorded earlier inventory. zipalign -P16 proves ZIP placement, not ELF LOAD-segment compatibility. The known libcrypto 16KiB limitation must remain named if unchanged; do not claim blanket Android 16KiB-device support.
3. Preserve the explicit absence of an ARM64 real-phone test and broader ROM/weak-network/performance matrix. Do not relabel x86_64 Debug emulator results as those gates. Local verify.ps1 missing-.env limitation remains as recorded.
4. Bind tool versions and build parameters to this run's recorded inputs/logs. Publication must use final.apk with that verified identity, never source.apk or unsigned/aligned intermediates.

This report is the specification gate before quality/security review. The completed artifact observations below resolve the earlier pending build-output state; no duplicate gate is requested.
## Completed artifact review

The final 20-row steps.tsv records zero exit codes for every expected step through rebuild-verification. Receipt records 2026-10-16 10:34:49–10:44:06 +08, source HEAD 35f59abbb6bdaa0fe6c826aaff904130bb6dea76, target lib/main.dart, standard arm64-v8a Release, package com.liuhetong.mobile and version 0.4.47+2216.

- Final artifact: arm64-final/final.apk, **73,262,170 bytes**, SHA-256 **db914f66229cffa79825954200845ac841fd10486c77fb8ecce94dbef7b41039**. Independently recomputed final APK hash matches the receipt, final-release-payload, final-assets, native-static and collector binding.
- apksigner reports exactly one RSA-3072 signer, expected 75b31 certificate and v2/v3 verification; signed ZIP alignment step exits zero. aapt confirms production package/version/arm64 with no application-debuggable marker. Source and final ABI gates pass.
- Asset check records 246 declared source assets, 225 SVG emoji, two icon fonts, 56 remote manifest-bound emoji and zero bundled animated WebP. Rebuild comparator reports 25,414 preserved classes, 168,863 methods, matching six-DEX inventory, identical manifest semantics and 274 unchanged native/asset entries. DEX binary bytes appropriately change under conventional rebuild while checked smali semantics remain equal.
- Frozen-after verifies the same 2113-file input identity and dependency lock. Collector requires no mobile diff from the full-host source, the same dependency-lock SHA and the precise four emoji-only changes since the earlier native fixture run. This supports reuse of 6038 PASS / 9 SKIP and the existing native fixture results with the actual-main autoplay follow-up, without rerunning the full suite.
- Final native libraries are byte-identical to the source intermediate. Relative to the SHA-bound prior 2215 release, the 13 non-app libraries remain identical; only libapp.so changes. Matrix export contract is unchanged. native-static.json identifies only lib/arm64-v8a/libcrypto.so as failing the LOAD-alignment check and no final ZIP alignment failures. Inspector exit **1**, static_16k_checks_pass=false and runtime_16k_verified=false are preserved; libcrypto bytes and static observations match the earlier baseline. This known P1 risk is neither fixed by ZIP alignment nor waived by collector status=pass. No ARM64 real-phone acceptance is claimed.

## Final evidence identity

Independently checked current hashes:

| Evidence | SHA-256 |
| --- | --- |
| arm64-final/receipt.json | da5cc60355e33182d6065773b4e1104052fbb370c1c62a0efad909e7dd350ed2 |
| collect_gates.py | d54cecde90140af6c6895b45ceae86b09251a2720c70fb81c45bff54e00d2fb7 |
| gates/gates.json | c7a06b76d90ea2b1793245df9e69f6ef732c37b10916e1f07303102957cc3130 |
| gates/shared_flutter.json | 0f96b5c84bf62d6591be3ee961741cf27f34faeda71f9d759d8c6e30bb3f5954 |
| gates/native_android.json | bcadbbbed0b2365beda76447270902db874fd1c6a978cbbda849e9596a9f63ac |
| gates/final_apk.json | ac8e2d76bd916d2bb0367d7474a81c680931e2d504f937b5e6df75c3bae1fbd5 |

Collector source and emitted evidence bindings were inspected; all three child hashes agree with gates.json. Root reports the collector invocation exited 0 with BOUND_EVIDENCE_PASS. This reviewer did not execute the collector or any test/build. Source-build logs retain plugin Kotlin/deprecation/unchecked-operation diagnostics; passing build is not described as warning-free.

No new actionable build-spec defect remains. Quality/security review may assess this exact artifact and preserved limitations. Backend publication preparation still requires its separate frozen review, followed by root-owned upload/integrity/platform-isolation/ordinary-popup/audit checks.