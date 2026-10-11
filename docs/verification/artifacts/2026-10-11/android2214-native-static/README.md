# Android 2214 native static review

Owner: review_media_android. Authorization is the parent's bounded read-only final-artifact task. Only this new artifact directory is owned. No mobile source, dependency, APK, signing identity, root HEAD, build or deployment is changed. The prior search-grid task is complete and separate.

The actual source and rebuilt final APKs were inspected after the builder completed on 2026-10-11. Inputs are build run `run-20261011-175600-r3`, source commit `e9d297b2b49c8b2198fb3225bf7e04ed80ab4bd8`, mobile manifest `f7a9a63d118bb39994907e6d37e8179ebe3f78cb75e18db6ac0141b96b29a687`.

- Source APK: `e56016e96962a88c6bb784ebf6d95110e4ab0dfdd95e0da63af2bdbb872d3509`.
- Final APK: `575e24f4c841ed2388311ba19c06e23623838022ed2a438df6c56642436af614`, 73,336,097 bytes.
- Official 2213 baseline: `08a7448114ad5d768b534b81b61668e03a71a2c26f95e894297e098838f15271`.
- Locked OpenSSL AAR: `a5b05c4b362d35c022238ef9b2e4e2196248adea3bac9dd683845ee75a3a8d66`, Maven `com.android.ndk.thirdparty:openssl:1.1.1q-beta-1`, selected by `flutter_openssl_crypto 0.5.0`.

## Actual results and limits

The final 14 ARM64 library entries have exactly the same names and decompressed SHA256 bytes as source.apk. All 14 final entries are stored, with ZIP local data offsets divisible by 16,384. This is ZIP geometry only; the parent's completed zipalign/signature/rebuild gates are not rerun or replaced.

All 13 non-libapp native libraries are byte-identical to 2213. libapp changes with application code. The final libcrypto SHA remains `13593ad654a00866f14a95c7bd07d6cb898c132817f92fd91adf6eb218842831`. It differs from the raw unstripped AAR entry, but every SHF_ALLOC section's address/type/flags/size/content, dynamic export set, SONAME and NEEDED set match the AAR. This is a strip-aware static correspondence check, not an executed cryptographic known-answer test.

The actual frozen Matrix ffi.dart declares twelve mandatory function lookups and the alternative EVP_MD_get_size / EVP_MD_size lookup. The final library exports all twelve plus EVP_MD_size. NDK readelf independently confirms these thirteen as defined global FUNC symbols. SONAME is libcrypto.so; NEEDED is libc.so and libdl.so. Static name/type presence does not by itself prove every calling convention or cryptographic output.

The existing P1 remains: libcrypto has four PT_LOAD segments aligned to 4,096 bytes and fails the 16 KiB offset/address congruence check. Other libraries' PT_LOAD alignment values are at least 16,384. ZIP alignment does not resolve this ELF condition.

The current official [Android page-size guide](https://developer.android.com/guide/practices/page-sizes), “Check the RELRO security flag,” separately gives `(VirtAddr + MemSiz) % 0x4000 == 0` and describes protection of a following writable sub-range. We report the raw modulo and actual writable PT_LOAD intersections rather than calling all nonzero observations reproduced crashes. Ten library RELRO endpoints are nonzero, all matching their 2213 counterparts. Only libcrypto has a writable PT_LOAD intersection between that RELRO endpoint and its next 16 KiB page boundary. The other nine have no such intersection in this geometry check. Bionic protection policy, compatibility mode, mappings and execution on a 16 KiB device remain untested. No newly reproduced device failure is claimed.

Accordingly the inspection intentionally exits 1, retains `static_16k_checks_pass=false` and `runtime_16k_verified=false`. Byte correspondence and required exports passed their separate checks. Missing/malformed/drifting inputs return 2 and do not create a success report. This artifact is not approval to replace OpenSSL or a claim of complete 16 KiB compatibility.

## Evidence and reproducibility

- `inspect_native.py`: bounded standard-library ELF64, dynamic sections/symbols and ZIP parser. Inputs are read-only, duplicate entries rejected, native byte limits enforced and APK/AAR identities checked before and after reads. Existing output is never overwritten.
- `test_inspect_native.py`: ten initial RED failures for missing checker behavior, then ten PASS; one additional RELRO geometry RED, then eleven PASS. Fixtures cover ZIP16/ELF4 separation, independent RELRO endpoint observations, compressed/duplicate ZIPs, malformed ELF, changed/missing library bytes, stripped nonallocated data, undefined exports, Matrix fallback and missing artifacts.
- `native-static-final.json`: complete structured actual result; use this for root's combined final-APK report. `native-static-r3.json` is the earlier same-byte inspection with overbroad RELRO “failures” field naming, retained with `inspect_native_initial.py.txt` and its receipt, superseded by the final observation/limits wording and added geometry.
- `crosscheck_readelf.py` and `readelf-final/`: NDK 28.2.13676358 readelf consumes each real library through stdin. Every LOAD/RELRO offset, address, size and alignment matches the independent Python parser. No binary extraction or mutation occurs. Required function symbols and dynamic SONAME/NEEDED raw outputs are retained.
- `baseline-comparison.json`: per-library baseline byte identity, RELRO modulo and writable-tail overlap.
- `evidence-manifest.json`: exact scripts, reports, receipts, tests, raw outputs and locked dependency/build inputs. Runtime build/signature/full Flutter gates belong to the parent; this task does not rerun them.

Command shape: `python inspect_native.py --source <source.apk> --final <final.apk> --baseline <official2213.apk> --aar <locked.aar> --ffi <frozen Matrix ffi.dart> --output <new-report.json>`. Every input is required; there is no placeholder production action. Then `python crosscheck_readelf.py <report.json> <NDK llvm-readelf.exe> <new-output-directory>`. Reports record the actual paths and hashes.

Next step: non-author SPEC/domain then QUALITY/security review of these scripts and exact APK evidence, followed by the parent's combined report. No runtime/device acceptance, publication or native repair is claimed here.
