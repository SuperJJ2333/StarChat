# Next candidate: fixed defaults and real native vectors

This is a proposed next task, not work implemented or a passed gate. Root accepted the boundary on 2026-10-11: freeze this isolated proof, do not change the current release's crypto dependency or binaries. Absence of 16 KiB runtime evidence means this experiment must not be inserted into that release.

## Reproducible production prefix

The old AAR's actual `libcrypto.so` embedded strings, recorded in `build-static-analysis.json`, establish these defaults:

| ABI | OPENSSLDIR | ENGINESDIR |
| --- | --- | --- |
| ARM64 | `/src/openssl/build/port/install/Arm64` | `/src/openssl/build/port/install/Arm64/lib/engines-1.1` |
| x86_64 | `/src/openssl/build/port/install/X86_64` | `/src/openssl/build/port/install/X86_64/lib/engines-1.1` |

The next minimal candidate should use these exact fixed logical Configure prefixes/openssldirs, with a separate local `DESTDIR` for `install_sw`. No build should write into the logical `/src` tree. If Windows is retained, verify the bytes embedded in the final shared objects because MSYS can convert `/src/...` arguments to host drive paths; explicitly scoped argument-conversion handling or a pinned Linux builder must be reviewed and recorded. Retain the proven target21, O3/assembly features, unversioned SONAME, headers and dynamic dependencies. Rebuild and assign new hashes after correcting these defaults; do not promote the local-path proof binaries.

Do not substitute `/system/etc/security` as an unrelated cleanup. That changes OpenSSL configuration/certificate lookup behavior. The Matrix code inspected here uses EVP digest/cipher/KDF functions; this experiment does not establish that a platform trust-store change is needed or equivalent. Any intended change in trust lookup needs its own domain review. Resolve the historical ndkports q recipe/patch provenance or explicitly review that remaining uncertainty before describing the candidate as an identical-configuration rebuild.

## Smallest useful native fixture

Create a separately reviewed test-only `integration_test/openssl_vectors_native_test.dart` on a new candidate. It must import the existing Matrix native crypto and encrypted-file implementation, use the packaged `libcrypto.so`, and avoid mocked crypto, a Dart fallback or a different host OpenSSL. Existing entry points inspected are `third_party/matrix/lib/src/utils/crypto/native.dart`, `ffi.dart`, `encrypted_file.dart` and `NativeImplementations.decryptFile`.

1. **Identity and loader admission.** Record APK/library SHA, ABI, OpenSSL version, device/build fingerprint and process mapping to the installed APK library. Compare the packaged library to the reviewed candidate. Measure page size both in-process using libc `getpagesize()` and through `adb shell getconf PAGE_SIZE`. An explicit expected-page-size input must fail on mismatch, not skip the fixture or relabel a 4 KiB result as 16 KiB.
2. **Known-answer functions through the SDK.** SHA1/256/512 with empty, short and multi-block input; PBKDF2-HMAC-SHA1 including 1/2/4096 iterations and embedded-NUL password/salt from [RFC6070](https://www.rfc-editor.org/rfc/rfc6070); PBKDF2-HMAC-SHA256 with independently generated and frozen expected bytes plus the actual recovery iteration/output-length contract; AES128/256-CTR using [NIST SP800-38A appendix F.5](https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38a.pdf), including zero, partial and multiple blocks. [RFC6234](https://www.rfc-editor.org/rfc/rfc6234) provides SHA-family implementation/test material. Do not derive an expected output by calling the same candidate function under test.
3. **Real Matrix attachment path.** Use synthetic fixed key/IV and compare full ciphertext, hash, key/IV encoding, and decrypted bytes. Cover lengths 0/1/15/16/17 and a bounded multi-block input; verify the caller's input remains intact. Call the production native/isolate decrypt path as well as deterministic `encryptFileWithKey`. Corrupted ciphertext/hash must fail according to the current SDK contract. CTR itself does not authenticate a wrong key; do not invent a wrong-key rejection assertion for bare CTR. MAC/authentication rejection belongs to the actual recovery/secret-storage boundary.
4. **Existing-data and repeatability.** Use synthetic old-version attachment/recovery fixtures produced by the unchanged baseline; decrypt/derive identical outputs on the candidate, and verify the current MAC/authentication failures at their real boundary. Repeat SDK encrypt/decrypt and digest/KDF calls after varied allocations and across fresh isolates to exercise FFI buffer lifetimes. Do not log real keys, messages or attachment data.

## Independent FFI risk to verify

Static inspection found an existing width mismatch candidate: `ffi.dart` declares EVP encryption length outputs as `Pointer<IntPtr>`, and `native.dart` allocates/reads `lenMem` as `IntPtr`; OpenSSL's C interface uses `int *` for these lengths. On a 64-bit target this deserves an independent actual native test, including repeated allocations and correct output lengths. It was not introduced by this experiment. **No production out-of-bounds access or crash was reproduced here**, and no binding was changed. Do not test only a C harness and thereby bypass the production Dart FFI path; if a native probe confirms a bug, isolate its RED evidence and protected fix from the linker-layout task.

## Separate execution gates

| Environment | What success can establish | What it cannot establish |
| --- | --- | --- |
| ARM64, measured 4096-byte pages | Actual ARM64 loading, SDK/FFI/vector and baseline-data compatibility on the control | Native 16 KiB compatibility |
| x86_64, measured 16384-byte pages, compatibility mode identified/disabled | x86_64 16 KiB loader and SDK behavior | ARM64 code/assembly execution |
| ARM64, measured 16384-byte pages, compatibility mode identified/disabled | ARM64 16 KiB loader plus real SDK/vector behavior for the inspected build | An uninspected future APK or unrelated library's compatibility |

A 4 KiB emulator with aligned ELF files does not meet the second or third gate. Use the official [Android page-size procedure](https://developer.android.com/guide/practices/page-sizes) to establish the runtime mode. Keep the ABI/page-size/device records separate even when they share the same test source. If only the 4 KiB control is available, report that result and keep 16 KiB acceptance open.

After domain and Quality/Security approval, the final integration should resolve exactly one fixed, source-built Prefab provider via project-scoped substitution of the existing Maven coordinate. Verify its resolution graph, packaged library hashes, all final APK libraries' ELF layout, ZIP alignment, established signer and normal rebuild gates. The actual signed delivery artifact must be inspected and installed; none of these release checks is supplied by the current static experiment.
