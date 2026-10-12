# Android2215 builder preparation: SPEC/domain review

Scope: the independently prepared Android ARM64 builder and strict historical static lock-boundary closure, starting from `e9878d5dd7d7f4681feb900b1af5817df7b43e68`. This review precedes the quality/security report. It does not review a built 2215 APK or authorize publication. The original e987 rejection is retained in `e987-rejection.md`.

## Specification and domain checks

1. The source contract is `0.4.46+2215`, standard ARM64 release, true `lib/main.dart`, existing production HTTPS endpoints, normal AOT and no Dart/R8 obfuscation. An unchanged exact pub.dev lock and source freeze are required. The builder has no upload or device-install action.
2. The source build is an intermediate. The builder still performs the prescribed conventional decode/rebuild, alignment, existing fixed signing identity, signed alignment and independent final decode/semantic checks. Complete Flutter assets/native ZIP bytes, methods and manifest must agree between source and rebuilt final APK. The bounded default static-field normalization belongs to the unchanged independently reviewed semantic verifier; no weakening was introduced here.
3. The restored signer must preserve `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`, one RSA3072 identity, v2/v3 signatures and existing alias. Original e987 failed the operability requirement by copying the pre-fix DPAPI reader. Its synthetic RED is independent of the otherwise passing preparation tests.
4. No financial, authentication, E2EE or media product behavior changes appear in this candidate directory. The original pinned dependency/native domain is preserved. No server recovery keys, plaintext messages or attachment content are introduced into evidence.
5. Reuse of the historical static lock-boundary result is bounded to all 400 Android/third_party/calls/dependency files and exact old final APK/receipt identities. Main pubspec normalization allows only the approved version replacement; other UTF-8 text permits CRLF representation normalization. The fixed binary files remain raw. This is not a new behavioral lock-screen test.
6. Final reuse additionally requires the new APK's entire 57 MainActivity/call-family smali inventory and bytes to match, rejecting added, missing or duplicate classes, and the whole AAPT manifest to match after only the exact build/name fields and element source-line coordinates. Attribute literals are not normalized. Source-only success cannot satisfy this final step.

## Independently read historical evidence

`independent-reference-closure.json` records actual checks of the old 73,336,097-byte final APK SHA `575e24f4c841ed2388311ba19c06e23623838022ed2a438df6c56642436af614`; its artifact, original lock receipt and original steps; all 400 original Git blobs at `e9d297b2b49c8b2198fb3225bf7e04ed80ab4bd8`; all 57 existing independently decoded class files; and the complete manifest. All match. The old successful final-lock-boundary step is unique. No repeat decode or new build was performed.

Current root at read time `e432414276af7d6fe73afd9afc8b41d7bfd4b5b7` passes the 400-file source boundary with only the approved version normalization. This is a point-in-time source check, not a binding of a future artifact to that source. Future builder freeze/readbacks and final artifact review remain necessary. A separate read-only peer corroborated these findings and confirmed the fixed 11 PNG and 5 OGG files all follow the raw-byte branch; the UTF-8/NUL text heuristic is not a generic promise for future binary inventories.

## Required scope of later evidence

The shared Flutter gate must cover the actual media-startup fix and final source. The native gate must report the actual main-debug media selection/send reproduction and repair with device/ABI and input identity; fixture storage tests or a desktop SQLite double cannot replace this. Final ARM64 package checks, exact signing, final smali/manifest closure and native ELF inspection are still due. ZIP `-P 16` alignment does not close the existing libcrypto 4 KiB/16 KiB limitation. No OEM, final ARM64 phone, iOS signing/device, background-delivery or performance-SLO acceptance follows from this preparation review.

## Final SPEC/domain decision

**PASS for preparation only**, candidate `45341ce97e60e7ceee55675f725e1dec0357b36a`, whose parent is e987. The incremental specification review verified 35 exact Git blobs, all 34 input-manifest entries and eight tool pins. The corrected signer exactly equals root commit `3edbf0031e540a1ee067f9e686475b3227f5ac5b` and SHA `eef1c12edf36c800166447911e6cc08f56ebb53224d7b24a40670ea07d1413a4`. It changes only serialized DPAPI `.Trim()` in the existing signer; the builder and 12 enumerated baseline/closure/semantic inputs remain byte-identical. Source/tool/input provenance was updated. A new test-only runner pins the existing synthetic test and cannot execute the signing wrapper main body.

Original e987 remains a rejected historical input. The corrected candidate closes that specific operability blocker without changing the fixed signing or domain contract. See `45341-input-identities.json` and `preparation-review.json`. The next executable step belongs to root: freeze the real final source, obtain a fresh production-version observation, then run the default candidate preflight. An actual build and final-artifact gates remain separate.
