# Android 2215 actual ARM64 native independent review

This bounded review owns only this `native/` evidence directory. Existing reviewed inspection tools read the APK, AAR and Matrix FFI inputs. No source, root artifacts, APK bytes, signing identity or dependencies were changed; no build, signing, tests, device/ADB or remote operation was performed. Python bytecode writes were disabled. The parent performs the overall package review.

## SPEC/domain result

The actual artifact identities match the delegated scope:

| Input | SHA256 | Bytes |
| --- | --- | ---: |
| 2215 source APK | `25a6f85774dd5011fc78d675c3958e4168aeed46d3a1bddf2131f943e0387918` | 72,977,996 |
| 2215 final APK | `4b43bd1ca655918b9754183c1713ed5eb6e864379a2e2ccc6bd861195578b6a6` | 73,262,170 |
| Actual 2214 final APK | `575e24f4c841ed2388311ba19c06e23623838022ed2a438df6c56642436af614` | 73,336,097 |
| Locked OpenSSL AAR | `a5b05c4b362d35c022238ef9b2e4e2196248adea3bac9dd683845ee75a3a8d66` | 6,778,965 |
| Actual Matrix ffi.dart | `fb357590ab33b9b26c9a0660615be62b5500042f0b6f4d332eee43b38c1fe1eb` | 5,124 |

The initial inspection finished at 2026-10-12 13:37:28 UTC. SPEC/domain findings were sent to the parent before the independent NDK quality crosscheck began at 13:38:06 UTC.

All 14 native library names and decompressed SHA256 bytes match between 2215 source and final APK. There are no added or missing native entries. Every final native entry is ZIP_STORED with its local data offset divisible by 16,384. The actual Matrix FFI file declares twelve mandatory function lookups plus the EVP_MD_get_size / EVP_MD_size alternative. The final libcrypto exports all twelve and EVP_MD_size. The strip-aware allocated sections, export set, SONAME and NEEDED projection matches the fixed OpenSSL AAR. Raw AAR libcrypto bytes differ because this comparison includes stripped versus unstripped artifacts; raw identity is not claimed.

The reused inspector has a fixed official 2213 baseline contract, so its `baseline_2213` field intentionally remains 2213 (`08a7448114ad5d768b534b81b61668e03a71a2c26f95e894297e098838f15271`). The separate `delta-2214-to-2215.json` compares the actual 2214 APK and its existing final static report against 2215; it does not substitute 2214 into the old tool's 2213 argument.

## QUALITY/security result

No new native byte or ELF-layout regression was found relative to actual 2214 within this static scope. Thirteen libraries are byte-identical. Only `libapp.so` changed, with size 19,268,496 bytes in both packages: old `a30a2a0d7a201b57b609fff0939ff64b7eaf72519c638460057a9c3926ac5070`, new `4c2fa9c271d36f36cbadfc1f07f24df94c8eeda37a709be2f49365089cd6dfc0`. Every library's LOAD and RELRO geometry, including libapp, is identical to 2214. The old report's complete per-library fields were independently recomputed from the old APK and matched. The delta JSON records all fourteen full hashes, sizes, ZIP offsets and old/new LOAD/RELRO structures.

NDK 28.2.13676358 `llvm-readelf.exe` SHA256 `2646e382d8b2559b5c4ae91e9a98e187ed9bd59f23936054d424049ef795ba5e` independently matched every LOAD and GNU_RELRO offset, virtual address, file/memory size and alignment for all fourteen actual libraries. It consumed library bytes through stdin without extracting binaries. It also confirmed the thirteen required/alternative exports as defined global FUNC symbols. The raw dynamic output records SONAME `libcrypto.so` and NEEDED `libc.so`, `libdl.so`.

The existing P1 16KiB limitation is retained. `libcrypto.so` remains `13593ad654a00866f14a95c7bd07d6cb898c132817f92fd91adf6eb218842831`, 2,594,184 bytes. All four PT_LOAD `p_align` values are 4,096; `(vaddr - offset) % 16384` is respectively 0, 4096, 8192, 12288. Other libraries have LOAD alignment at least 16,384. ZIP alignment does not repair ELF segment alignment.

| Library | PT_LOAD count | Alignment | RELRO end modulo 16384 | Writable tail intersection |
| --- | ---: | ---: | ---: | --- |
| libapp.so | 3 | 65536 | No RELRO | None |
| libbarhopper_v3.so | 3 | 16384 | 0 | None |
| libc++_shared.so | 4 | 16384 | 8192 | None |
| libcrypto.so | 4 | 4096 | 8192 | `[0x27a640, 0x27c000)` |
| libdartjni.so | 3 | 16384 | 0 | None |
| libdatastore_shared_counter.so | 3 | 16384 | 8192 | None |
| libflutter.so | 3 | 65536 | 4096 | None |
| libflutter_openssl_crypto.so | 2 | 16384 | 4096 | None |
| libimage_processing_util_jni.so | 3 | 16384 | 0 | None |
| libjingle_peerconnection_so.so | 3 | 16384 | 4096 | None |
| libolm.so | 3 | 16384 | 8192 | None |
| libsqlcipher.so | 3 | 16384 | 4096 | None |
| libsurface_util_jni.so | 2 | 16384 | 4096 | None |
| libzxprotect.so | 3 | 16384 | 12288 | None |

Ten libraries have nonzero RELRO end modulo, exactly as in 2214. Only libcrypto intersects a writable PT_LOAD between its RELRO end `0x27a000` and the next 16KiB boundary `0x27c000`; the intersection is `[0x27a640, 0x27c000)` (6,592 bytes). This is geometry, not a reproduced loader crash. Absence of RELRO in libapp is explicitly recorded rather than described as enabled hardening.

## Executed evidence and limits

- `inspection-receipt.json`: actual inspector **exit 1**, 0.8585236 seconds. `static_16k_checks_pass=false`, `runtime_16k_verified=false`; all input identities unchanged before/after. The empty stdout/stderr log is retained because this tool writes results to JSON.
- `readelf-crosscheck-receipt.json`: actual crosscheck **exit 0**, 1.3652967 seconds; all 14 program-header comparisons and 13 function exports match. This success describes parser/NDK agreement only.
- `delta-comparison-receipt.json`: actual read-only delta comparison **exit 0**, 0.6792854 seconds. Full old-report correspondence, actual old/new input binding, inventory and independent old/new readelf geometry checked; all input identities unchanged.
- `native-static-2215.json`, `delta-2214-to-2215.json`, and `readelf/` preserve the detailed structured results and raw NDK outputs. `evidence-manifest.json` hashes the local evidence files and records external tool/input identities.

This review does not approve the actual package, deployment, or 16KiB support. It does not prove Bionic page protections/compatibility mode, runtime ABI calling convention, cryptographic known-answer outputs, startup, message/attachment decryption or calls on either 4KiB ARM64 or 16KiB devices. Existing runtime/device acceptance and the libcrypto P1 remain with the parent. No shared Flutter/Python gates were repeated.
