# Android Modifier APK comparison

User supplied: `docs/verification/ChatFlow_2026年09月05日20点15分.apk`.
SHA256: `9b670805675b39d7a98a2e24b48fef3089c973b51707cead879dac124c34c326`.
Read-only inspection; no installation, scanner upload, APK alteration or production changes.

## Baseline and verified differences

The supplied APK identifies as com.liuhetong.mobile, version 0.3.38, versionCode 2041, ARM64, minSdk 24, targetSdk 36. It is not a processed 0.3.40 build. Therefore the same-version preserved `call-dismiss-release/ChatFlow-0.3.38-arm64.apk` is the primary baseline; comparisons against 0.3.40 also include product-version changes.

| Area | Original 0.3.38 versus supplied APK |
| --- | --- |
| Certificate | Official SHA256 b4784ac301d54add4157427713b136cb22cefd626e9c7a6092882e145c0b22f6 replaced by 9006f646ce1f594ed99f36989fe41af6976984040a553d175fc5a524e1653059 |
| Supplied public key | RSA 1024; certificate DN fields contain 0580ebd7. Public certificate does not establish how a tool derived its private key or whether it is exclusive to one computer. |
| Signature verification | Supplied APK verifies with v2 and v3. v1 does not verify as an active scheme despite META-INF signature-related files being present. |
| DEX | Five original DEX become thirteen. Four new DEX each contain nine classes; four additional DEX have no class definitions and are 140 bytes each. |
| Class inventory | Both contain exactly 24,570 distinct class descriptors; no class descriptors added or removed. This is not a proof of identical method implementations. |
| Native libraries | All thirteen common native libraries match byte-for-byte, including libapp.so, libflutter.so, libjingle_peerconnection_so.so, libolm.so and libzxprotect.so. |
| Permissions | aapt permission dumps are identical. No permission reduction explains the changed scanner result. |
| Manifest | Removes explicit extractNativeLibs=false and MainActivity taskAffinity=""; adds requestLegacyExternalStorage=true, explicit UCropActivity exported=false, and empty android:value on two metadata entries. XML line information also changes. |
| Resources | resources.arsc and compiled resource files change; resource paths are extensively renamed to descriptive names. At least 127 new resource paths have exactly the same bytes as original differently named resources. Rewriting is consistent with a resource decode/rebuild, not proof of a particular implementation tool. |
| Flutter assets | No added assets. Only statistics_tools_combined_v2.html changes: trailing whitespace plus one otherwise unused HTML comment. |
| ZIP | Original 986 entries (526 deflated, 460 stored); supplied 997 entries (537 deflated, 460 stored). |

## Interpretation and limits

The tool did much more than re-sign. The observed package has been structurally rewritten. The parent task's 0.3.40 diagnostic APK changed the signing identity while preserving all 986 functional entries; consequently it did not reproduce this tool's changes.

The retained class inventory, identical Flutter/native libraries, unchanged permissions and retained SDK components do not support claiming a malware payload was removed. They also do not constitute a comprehensive security verdict: Java method-level semantic equivalence and runtime behavior were not exhaustively proven.

The user's phone accepts this supplied APK and flags official 0.3.40, but multiple variables changed simultaneously. Possible explanations include scanner fingerprint/heuristic differences, certificate reputation, cloud verdict/cache, and product-version differences. Without the scanner's actual detection explanation and a same-version controlled scan, none can be singled out as the proven trigger. The alert string is a scanner verdict label, not a demonstrated file path or identified malicious function.

Independent reports with the same alert exist in the upstream Cromite repository: https://github.com/uazo/cromite/discussions/943 . This establishes that the label has appeared elsewhere; it does not prove that ChatFlow's result is a false positive or identify the engine on the user's particular HyperOS installation.

Recommended resolution: retain a stable release identity, submit the flagged original and this accepted sample with their hashes and the device/engine/version information to the relevant security vendor for a sample review. Fix any concrete behavior identified by that review. Treat the accepted repack as diagnostic evidence, not proof of disinfection or a reason to copy arbitrary resource/DEX mutations into production.

Artifacts under `artifacts/2026-09-05/modifier-apk-comparison/`: public certificate report, identity, permission dumps, normalized manifest diff, ZIP hashes, DEX class inventory, resource comparison and HTML diff. A byte-identical ASCII-path copy was needed because the local aapt binary could not open the original Unicode filename; initial aapt path failure was not an APK manifest error.
