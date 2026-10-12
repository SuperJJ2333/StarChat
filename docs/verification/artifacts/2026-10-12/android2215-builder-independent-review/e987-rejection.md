# Android2215 builder preparation: e987 rejection retained

Reviewed candidate: `e9878d5dd7d7f4681feb900b1af5817df7b43e68`. Reviewed in order: SPEC/domain, then QUALITY/security. This is a preparation review, not approval of an actual new APK or a publication package.

## Blocking finding

**P1, blocks builder execution:** `tools/sign-existing-identity.ps1:95` copies the old wrapper `1baf91b7c2e3ed7951c3c3f9fab623d9cf6355d3dc3a2eade29f58508183b7d0`. It feeds raw serialized DPAPI text, including the file line terminator, into `ConvertTo-SecureString`. The root coordinator had already observed `System.FormatException` with the real existing file before any signing. Independently executing the exact candidate assignment with a synthetic DPAPI value and a trailing line terminator reproduced the same exception: one expected FAIL, exit 1, 0.702 seconds. No real password, key or signing operation was accessed.

Required correction: copy the already reviewed wrapper `eef1c12edf36c800166447911e6cc08f56ebb53224d7b24a40670ea07d1413a4`, whose sole executable difference is trimming serialized DPAPI outer whitespace before decryption; update candidate tool, source and input identities. Preserve spaces inside the decrypted password. Rerun the focused synthetic regression against the actual corrected copied bytes. Do not substitute a new signing identity or relax certificate/argument/path guards.

## Other evidence, without overriding the rejection

- Exact Git export: 28 files; all 27 manifest hashes and eight helper pins matched.
- Seven closure and four guarded preflight tests independently PASS, 2.824 seconds. The real build tail was replaced with an unconditional throw before invocation; synthetic identity paths and read-only Python doubles were used. These tests do not exercise real signing and therefore cannot cover the blocker.
- Independently read the old 73,336,097-byte final APK and matched SHA `575e24f4c841ed2388311ba19c06e23623838022ed2a438df6c56642436af614`; original artifact, lock receipt and steps agree, with a unique successful historical `final-lock-boundary` step.
- All 400 frozen source Git blobs at `e9d297b2b49c8b2198fb3225bf7e04ed80ab4bd8` matched the baseline. Current root source at read time `e432414276af7d6fe73afd9afc8b41d7bfd4b5b7` matched these 400 after only the approved version normalization.
- The existing independently decoded old APK has exactly the frozen 57 MainActivity/call-family class bytes, with no duplicate paths, and the whole old AAPT manifest matches under only exact version and element-line normalization. It was read, not decoded again.

See `e987-input-identities.json`, `e987-independent-11.log`, `e987-independent-11-receipt.json`, `e987-signer-format-red.log`, `e987-signer-format-red-receipt.json`, `independent-reference-closure.json` and `e987-static-review.json`. No new APK, device behavior, 16 KiB compatibility, background/OEM delivery, iOS signing, performance SLO or publication success is asserted.
