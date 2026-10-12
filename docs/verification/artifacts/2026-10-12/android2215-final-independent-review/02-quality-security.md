# Android 2215 actual release — independent quality/security review

Result: PASS for execution of the exact r2 publication plan after specification/domain review. No new publication-blocking regression was found in the inspected scope. Existing P1 16KiB incompatibility and the missing broad runtime/performance evidence remain open. This decision authorizes a bounded P0 media-startup repair publication under those stated limits; it is not a compatibility waiver or a claim that publication has already happened.

## Evidence and independent checks

This report is bound to freeze `d08e5c8aa80af4429c6dd8d8a953279d907ceb4c4b281f684998036d1a9a558b`, APK `4b43bd1ca655918b9754183c1713ed5eb6e864379a2e2ccc6bd861195578b6a6`, runtime `2926e0b4c1ced432d97ca37e20a872f983c79f545e4b7d86babb06ebf4b27248`, source `9990ca6e752271d2a37610bc3be37e68f80a14c0`, and operation `mediafix-20261012-2215`.

| Check | Observed result and limit |
| --- | --- |
| Actual artifact/input/log identities | Source and final hashes, final size, all 28 raw build-step logs and bound metadata checked; original build steps exit0. |
| Independent actual signature | apksigner verify exit0; one RSA3072 signer, v2/v3, SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`. No signing/key access was performed by reviewer. |
| Independent actual ZIP alignment | zipalign `-c -P 16 4` exit0; this says nothing by itself about ELF runtime 16KiB compatibility. |
| Independent source/final media/native assets | All 274 inventory entries and decompressed raw bytes match, no absent/extra entries. |
| Original complete semantic rebuild | Recorded actual successful fixed-tool verification, 25,414 classes / 168,863 methods / whole manifest semantics; tool and inputs/report bound to actual build. |
| Independent historical lock boundary | All 57 class bytes match actual2214 baseline; complete manifest matches only after permitted version/element-line normalization; 400 source closure retained. No runtime extension of the old evidence. |
| Independent native inspection | 14 source/final native entries match, all required Matrix exports present; real llvm-readelf confirms geometry/defined symbols; unchanged known 16KiB failure retained. |
| Package validation | All 38 frozen hashes, safe exact 24-member archive, release/build/source identities and gate report hashes pass. Default `run(execute=False)` returned PLAN_ONLY without an execution directory or remote call. |

Evidence: [actual inputs](actual-artifact-inputs.json), [signature receipt](actual-independent-signature-receipt.json), [alignment receipt](actual-independent-alignment-receipt.json), [274-entry comparison](independent-native-assets-byte-equality.json), [57-class comparison](independent-final-lock-closure.json), [r2 delta](publication-r2-delta-review.json).

One additional read-only complete semantic replay did not finish within its explicit 180-second subprocess timeout. The wrapper completed exit1 after TimeoutExpired; no semantic result or difference was returned. It is recorded as UNFINISHED_TIMEOUT, not PASS, and no unsupported cause is assigned. The original actual build's complete semantic PASS is independently bound to source/final/tool/report, complemented by the direct checks above. No redundant rebuild or full test rerun was used to conceal this supplemental incomplete check. See [timeout record](actual-independent-semantic-timeout.json).

## Retained native finding

Actual libcrypto SHA256 `13593ad654a00866f14a95c7bd07d6cb898c132817f92fd91adf6eb218842831` is unchanged from the deployed2214 lineage. Its four LOAD alignments are4096; 16KiB segment congruence fails on three. Of ten nonzero RELRO-end observations, only crypto intersects a later writable LOAD tail when protection is rounded, `[0x27a640,0x27c000)` (6,592 bytes). The other nine observations are not represented as reproduced crashes. Thirteen of fourteen native libraries are byte-identical to actual2214; only libapp differs, while all fourteen LOAD/RELRO geometries are unchanged. Matrix's twelve mandatory lookups plus the supported EVP_MD_size alternative are defined global functions. The locked AAR strip-aware sections/exports/SONAME/NEEDED projection matches; stripped versus unstripped raw AAR identity is not claimed.

The actual native inspector exited1, readelf crosscheck exited0 and delta check exited0. The embedded final gate retains `static_16k_checks_pass=false` and `runtime_16k_verified=false`. This is a known open P1, not a successful 16KiB gate. No actual final ARM64 APK install on a real phone occurred in this review. The source-build KGP future-support warning is toolchain maintenance work, not proof of this build failing; current build/pinned tools remain unchanged.

## Executor safety and bounded publication

The exact executor/package/runtime scripts match the prior independent c1b1ccd review and its 32 passing synthetic/local tests. Imports/default plan do not perform remote actions. `--execute` requires the artifact/freeze/runtime/source/operation-bound pair of report hashes. Each write phase requires its predecessor receipt, exclusively records an attempt/inflight marker, and rejects repeats or an UNKNOWN outcome. Read-only inspect/audit do not clear UNKNOWN. After uncertainty, inspect first; do not replay a mutation.

Fresh live preflight is required again immediately before runtime installation. Captured schema, version/settings, static files, container/service state, guard/probe identity, account/role and CloudFront ETag/policy/Deployed checks remain enforced. A stored receipt does not replace fresh CDN HEAD/CORS/distribution checks before HK switch or publish. Runtime archive hash and member payload hashes are verified before use; programs use fixed staging locations, exact filenames, regular-file checks, verified SSH host keys and HTTPS certificate checks. Two permanent business guard hashes stay intact. No account secrets, APK signing passwords, session tokens, message plaintext or real wallet addresses were copied into these review reports.

Rollback remains bounded by expected current bytes/state and the captured before values. It is not a blind force-restore. Publish settings retain idempotency/audit/CAS protections and fail closed on drift. Production minimum3 stays unchanged; 2213/2214/2215 are not made forced updates, but this does not imply builds below3 can never be forced. Existing iOS state and financial state are preserved. Worker or wallet operations are not authorized by this Android review.

Authorized operations, in the existing executor's ordered flow: preflight, runtime, upload, assemble, hk-install, cdn-install, cdn-check, hk-switch, publish, inspect, audit. The parent's existing user authorization permits executing this concrete plan; this reviewer performed no production write and no device interaction.

## Source backfill execution rule

After successful publication/audit, the reviewed local reconciliation is executable without a new payload: read both target raw hashes and HEAD Git blobs, require each to equal its frozen before identity, then write the exact staged after bytes and record both after hashes. The two targets have exact raw/Git/production before equality; do not apply broad whitespace normalization.

For the five preserved source files, independently require HEAD Git identity to remain equal to each file's `9990ca6e` Git identity and require its local raw bytes to be identical before/after the two writes. Production guards continue using the separate captured production hashes. In particular, local/source `admin-home.js` has pre-existing cacheEpoch arguments absent from production (local SHA `5a33f4689a1fbd7ad3eb304dbf2b7e0f70f8334491fb9e519152a06935996190`; production `b804b6f98d9cf52a0f981e46049b1f8660313f57083119f8a810965f38015c27`). It must not be rewritten, published or forced equal. Three other preserved local files differ only by EOL and also must not be rewritten. These distinct identity domains are fully enumerated in [source-backfill review](source-backfill-review.json).

## Publication acceptance and stop conditions

Proceed only for the exact r2 package and current bound reviews. Stop on package/report/source drift, any failed live baseline/guard/CAS, unexpected service/static changes, absent required predecessor, UNKNOWN result or failed delivery/audit; preserve the receipt and diagnose before another mutation. Finish with actual distribution hashes/size/signature, both-site projection audits, release-settings assertions and exact two-file source-backfill receipts. These future outcomes are not predeclared here.

The limited actual API28 self-room media result, full shared mobile test evidence and packaging checks support this repair. The whole-verifier `.env` stop, retained skips, final-ARM64 real-device gap, OEM-push/ROM/weak-network/power/SLO gaps, iOS signing/device gap and P1 libcrypto 16KiB risk remain visible in the final release statement. No latency percentile, survival rate, OOM rate or all-device compatibility result is invented.
