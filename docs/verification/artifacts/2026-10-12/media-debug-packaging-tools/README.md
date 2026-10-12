# Media debug packaging tool restoration — 2026-10-12

Result: tools reconstructed and locally validated for root's independent review and subsequent actual debug build. **No signing, actual password read, ADB, remote call, app-code/native change, new key, or product fix was performed by this task.** The media session-generation fix and current source/debug APK are owned by the root/client-author task. These tools do not themselves prove that regression fixed.

Ownership: only this artifact directory in the existing `im-media-cache-review` worktree. The old sign/rebuild verifier scripts are unavailable in the four known verification trees, exact runbook paths and exact-name Git history searched. See [lookup record](restoration-lookup.json). This is a reconstruction under [the fixed APK runbook](../../../../runbooks/android-apk-rebuild.md), not recovery of the old bytes. Apktool 2.12.1 retrieval, source build, real signing and installation remain root-owned.

## Approved bounded contract / specification check (first)

The parent assigned recovery of the existing two build gates, with fixed key material and no native/E2EE relaxation. These purposes and constraints supply the bounded restoration design; no new product behavior or protocol is introduced.

- [verify_rebuild.py](verify_rebuild.py) keeps `py -3.12 verify_rebuild.py BUILD_DIR`. Expected inputs are `source.apk`, `final.apk`, `decoded/`, `verified-decoded/`, `original-manifest.txt`, `rebuilt-manifest.txt`. The latter two are actual `aapt dump xmltree <apk> AndroidManifest.xml` outputs. It compares every decoded class and full smali text, including every method and annotation. The only class-text normalization is a static field's exact typed default: `false` for Z; explicit integer-zero forms for B/S/C/I/J; `null` for reference/array descriptors. Instance fields, floating zero, numeric boolean zero, nonzero values and non-default changes are not normalized. Multi-DEX indices 10 and above are included. Class descriptors must be unique, methods balanced, DEX and decoded root inventories corresponding. AAPT element source-line coordinates alone may differ; namespaces, hierarchy, attributes and typed values remain exact. Both ZIPs reject duplicate/unsafe names; all `assets/` and `lib/` names and bytes must match; required DEX/manifest/resources and nonempty inventories are checked. Resource entry counts must match; binary resource table equivalence is not a claim of this tool.
- [sign-existing-identity.ps1](sign-existing-identity.ps1) preserves the documented P12, `password.dpapi`, alias and certificate SHA75b31…1fff / RSA3072. All identity constants are fixed. **Unlike the missing wrapper, this reconstructed wrapper requires both `-Apksigner` and `-Execute` for real signing. Default successful PLAN_ONLY does not produce an APK.** See [exact signing invocation and limits](signing-notes.md). Root must add these flags to its call instead of assuming the older argument list still signs.
- Signature verification, signed zipalign, package/version/ABI/debug identity, native ELF/page size and actual device tests are separate required runbook gates. This verifier neither invokes them nor treats ZIP alignment as 16KiB native compatibility. Existing crypto/native bytes are immutable under its asset checks.

Specification result: PASS for this assigned recovery scope. The replacement CLI differences are explicit, and no actual artifact output is claimed before root executes the tool against the new build.

## Quality / security check (second)

Signing-wrapper source was read independently after its author froze it. The plan exits before reading DPAPI. Execution rejects missing/empty prerequisites, same input/output, existing output, UNC/ADS, reparse ancestors and cmd expansion/metacharacters before secret access. P12 import uses ephemeral key storage and checks the public certificate and RSA3072 before invoking trusted SDK36.0.0 apksigner. Password appears only in memory and a unique process environment variable; arguments contain `env:<name>`, not the value. Tool stdout/stderr is captured without forwarding. The source must remain unchanged; a private temporary APK is verified for exactly one expected v2/v3 signer before a no-overwrite move. `finally` clears the environment, releases BSTR/SecureString/certificates and removes the task temporary file. No key generator or alternate identity fallback exists. Managed strings/forced termination cannot promise forensic zeroization; notes state that limitation.

Verifier review found and corrected two draft issues with retained failing evidence: multi-DEX regex originally missed index10+, and a valid package-private class with no access flag was initially rejected. Negative tests were added before correction. The final comparator remains conservative and does not drop comments, annotations or method directives to make actual data pass.

Quality/security result: PASS for restoring these local gates, subject to root's actual fixed-signature run and remaining packaging checks. Actual P12 import/alias/password validity is deliberately untested here. Caller must supply the trusted pinned apksigner; this helper does not verify arbitrary tool binaries on its behalf.

## Verification evidence

| Gate | Result and evidence |
| --- | --- |
| Missing-tool RED | One intentional missing-file failure, exit1: `verifier-red.log` |
| Multi-DEX RED | Two intentional guard failures, exit1: `verifier-multidex-red.log` |
| Package-private class RED | Valid class initially rejected, exit1: `verifier-package-private-red.log` and `known-2214-initial-red.json` |
| Final verifier synthetic | **28 PASS / 0 SKIP**, exit0: [log](verifier-green.log) |
| Independent signer synthetic/static | **18 PASS / 0 SKIP**, exit0, fake profile/P12/DPAPI only: [log](signer-independent-green.log), [timing receipt](signer-independent-green-receipt.json) |
| Actual prior 2214 read-only replay | **PASS**, 25,414 source/final classes, 168,863 methods, six DEX, 274 exact native/assets, 475 resource entries each, manifest exact except source-line coordinates: [result](known-2214-replay.json), [timing](known-2214-replay-receipt.json) |

The actual replay ran 11:32:48.885–11:36:10.798 UTC against already-decoded existing artifacts in root's `im-reliability-release/android-arm64/run-20261011-175600-r3`. It binds source APK `e56016e96962a88c6bb784ebf6d95110e4ab0dfdd95e0da63af2bdbb872d3509` and final APK `575e24f4c841ed2388311ba19c06e23623838022ed2a438df6c56642436af614`. It did not rebuild, re-sign or retest Android2214 on a device. This prior-artifact tool validation is not evidence for the new P0 fix candidate.

Signer author RED/GREEN stage details are recorded in `signing-notes.md`; the independent final run above is archived as raw local evidence. One test-only PowerShell junction setup was given the mandated UTF-8 initialization before the independent run. No product dependencies, generated registrants or shared files were changed. Tests/fixtures stay within this named verification directory. Full product `verify.ps1` is not rerun for this isolated packaging-tool restoration; focused synthetic guards plus unchanged known-artifact replay are the applicable evidence, and root continues the current product candidate's own gates.

Next executable step: root independently reviews the two tool files and [input hashes](tool-evidence-identities.json), then uses its real aligned debug APK with the explicit signer flags and runs the comparator on that build's own two decoded trees/AAPT outputs. Stop on any failed check; do not substitute old2214 success for new-candidate gates.

Recorded UTC: 2026-10-12T11:40:05.478996+00:00
