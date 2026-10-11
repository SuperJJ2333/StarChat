# OpenSSL 1.1.1q / Android 16 KiB isolated build proof

Date: 2026-10-11. Owner: review_r1_r2. This extends the read-only plan frozen in `f93cc4d5c9dc188c2cd618d9a146fac2b95f72f5` under root's explicit isolated-build authorization. Only this artifact directory was used for source/build inputs and outputs. No client, Gradle, Pub/Maven cache, iOS, release-preparation payload, production service or root candidate input changed. Two empty directories accidentally created by the first shell probe are disclosed below.

## Result and scope

**The existing Windows host can rebuild the official unmodified OpenSSL 1.1.1q source for ARM64 and x86_64 with 16 KiB LOAD and RELRO layout.** The executable static gate passed for both `libcrypto.so` and `libssl.so` in each ABI. This is a build feasibility result, not an integration or release approval.

| Static comparison against the existing pinned AAR | ARM64 | x86_64 |
| --- | --- | --- |
| All LOAD alignments at least 16 KiB, offset/address congruence | Pass | Pass |
| GNU_RELRO present, end divisible by 16 KiB | Pass | Pass |
| Exported crypto symbol names including versions | 4,398 identical; zero added/removed | 4,398 identical; zero added/removed |
| Exported SSL symbol names including versions | 495 identical; zero added/removed | 495 identical; zero added/removed |
| SONAME and NEEDED for both libraries | Identical | Identical |
| Preprocessed `OPENSSL_*` configuration macros | Identical | Identical |
| Matrix FFI's required functions including digest-size fallback | Present | Present |

The crypto SONAME is `libcrypto.so`; dependencies remain `libdl.so` and `libc.so`. All 3,095 regular files extracted from the official source archive were checked byte-for-byte after compilation and remain unchanged. Full symbol sets, program headers, embedded compiler strings, configuration macros and hashes are in `build-static-analysis.json`; independent NDK `llvm-readelf` output is in the four `*-readelf.txt` files. `build-static-analysis.log` is the actual assertion-based gate output.

No Android library was executed here. There are no cryptographic known-answer, Matrix SDK protocol, encrypted attachment/recovery, APK packaging, 4 KiB device or 16 KiB device results. Same-version rebuilding does not resolve the maintenance/security risk of an old OpenSSL version.

## Exact inputs and output identities

The [official OpenSSL archive](https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1q/openssl-1.1.1q.tar.gz) was downloaded with HTTPS verification and checked against the [official checksum](https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1q/openssl-1.1.1q.tar.gz.sha256):

- Source: 9,864,061 bytes; SHA256 `d7939ce614029cdff0b6c20f0e2e5703158a489a72b2507b8bd51bf8c8fd10ca`.
- Baseline AAR: `com.android.ndk.thirdparty:openssl:1.1.1q-beta-1`, SHA256 `a5b05c4b362d35c022238ef9b2e4e2196248adea3bac9dd683845ee75a3a8d66`.
- NDK: existing Windows `28.2.13676358` / r28c, Clang19.0.1; GNU Make4.3 from that NDK; Git MSYS Bash5.2.37 and Perl5.38.2.
- Missing documentation-only Perl modules: 37 real files, 623,926 bytes, fetched from the [official Perl5.38.2 commit](https://github.com/Perl/perl5/tree/55dd2f792ffc8cefe614350a411f785374281b24), placed only in `perl-support/`, selected through process-local `PERL5LIB`. Every Git blob ID and SHA256 is recorded in `perl-support-inputs.json`. No stub was substituted for a required module, and the installed Perl was not changed.

`build-tool-inputs.json` records 17 input/executable hashes, tool versions and host identity. Raw GitHub module download initially reset the TLS connection; verified GitHub API blob retrieval succeeded. Both fetch evidence and all build failures are retained.

| Output (unstripped; local, ignored, not a distribution artifact) | Bytes | SHA256 |
| --- | ---: | --- |
| `build-arm64/libcrypto.so` | 3,105,904 | `ad8a69815d2ea8c0e7b0bc2259c7f2d374e09420922f3097fbf99022cef1b8fb` |
| `build-arm64/libssl.so` | 679,600 | `86e4ea11e36735d7bb529a5c81d757e2d9a49360d6c7baa2137fa59291248610` |
| `build-x86_64/libcrypto.so` | 3,231,104 | `042b39c8bd02aaa9131070820d644a74c3366b535f5332b72e9782835369e325` |
| `build-x86_64/libssl.so` | 673,128 | `63c9c3b1c3002d576f3dbe991e785548158befc5cfeb92a0e40aefca2e7ce6b9` |

## Recipe, failures and timing

`build-recipe.sh` uses `android-arm64` / `android-x86_64`, API21, `no-sctp shared`, upstream O3 and assembly defaults, `SHLIB_EXT=.so`, and explicit `-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384`. Make is limited to `-j2`; ABIs were built sequentially. Direct `clang --target=<triple>21` is the [NDK-documented invocation](https://developer.android.com/ndk/guides/other_build_systems) and avoids the Windows target `.cmd` wrapper's command-line limit. The [Android guidance](https://developer.android.com/guide/practices/page-sizes) treats ELF layout, ZIP alignment and actual execution separately.

Each `build-*-attempt-*.json` has the UTC start, duration, exit code, recipe SHA and exact raw log SHA. Attempts are not combined into an invented single all-green run:

| Attempt | Result |
| --- | --- |
| ARM64 1 | Failed before Configure: Git `dirname` absent from inherited PATH. Fixed process PATH before resolving the artifact directory. |
| ARM64 2 | Configure reached generation, then missing genuine `Pod::Usage`. |
| ARM64 3 | After initial local modules, missing genuine `Pod::Escapes`; fetched the matching official module. |
| ARM64 4 | Configure passed; native Windows Make could not resolve MSYS absolute `/c/...` source prerequisite. Use a relative source path. |
| ARM64 5 | Native Make converted absolute `PERL5LIB` into a Windows drive path, which MSYS Perl split at `:`. Use artifact-relative `../perl-support`. |
| ARM64 6 | Started 08:47:09.946 UTC, 162.250 seconds. C/ASM compilation completed; target `.cmd` wrapper rejected the long crypto link command. Exit2 retained. |
| ARM64 7 | Started 08:50:38.247 UTC, 2.141 seconds. Resume with direct Clang target; same completed objects, successful links, exit0. |
| x86_64 1 | Started 08:50:51.682 UTC, 123.640 seconds. Fresh configuration, C/ASM and links using direct Clang target, exit0. |

The first failed probe created empty `build-arm64/` and `install-arm64/` at the author-tree root before its source lookup failed. Read-only inspection confirmed both empty. Automated approval rejected the attempted empty-directory `Remove-Item` cleanup with only `blocked by policy`; no bypass or second deletion mechanism was attempted. All actual source/build files are below this verification artifact path. No other worktree was affected.

Warnings were not suppressed. Clang19 diagnoses the original explicit `-D__ANDROID_API__=21` against its built-in macro alias of `__ANDROID_MIN_SDK_VERSION__`; the target remains API21. Three existing upstream variables are set but unused (`pem_lib.c:794`, `txt_db.c:24`, `x_name.c:496`). GNU Make reports duplicate shared-library target aliases when `SHLIB_EXT=.so` collapses the versioned/unversioned names; LLVM `ar` reports creation of new static archives. `build-warning-summary.json` records the raw categories/counts. These are documented observations, not a warning-free release gate or authorization to patch upstream crypto code.

## Differences that remain before a production candidate

1. **Historical recipe provenance remains incomplete.** The exact old ndkports q commit/patch set has not been recovered. Matching configuration macros, assembly flags and symbols is strong static evidence but does not prove historical source/recipe equivalence.
2. **The toolchain changes from the AAR's NDK25 to NDK28.2.** Real crypto known-answer tests, SDK attachment/KDF/recovery compatibility, failed-authentication behavior, owner/account and native execution gates remain required. Neither symbols nor the x86_64 build can replace ARM64 runtime evidence.
3. **This experiment embeds local build paths.** Its `OPENSSLDIR` and `ENGINESDIR` differ from the old AAR's `/src/openssl/build/port/install/{Arm64,X86_64}` paths. Do not directly promote these proof binaries. A production recipe must deliberately preserve or separately review these defaults, including MSYS argument conversion, then freeze new outputs. ARM64's compiler string names the target wrapper because its objects were compiled before the direct-link retry; x86_64 names direct Clang. Both preserve target21/O3/assembly feature flags.
4. **No AAR was created or substituted.** A future narrow integration should use a fixed-version, hash-locked project-scoped dependency substitution for the exact old Maven coordinate, preserving Prefab modules/headers/SONAME and source licenses. Domain and Quality/Security review precede integration; the currently frozen2214 root inputs must remain unchanged until that decision.
5. **Actual platform gates remain open.** Run true crypto/SDK vectors and library loading on ARM64 4 KiB and 16 KiB controls, identify compatibility mode, then inspect the exact final rebuilt/signed APK's libraries and ZIP alignment. The current proof has no authority to mark device, iOS or whole-app compatibility PASS.

Next executable step: root reviews the bounded proof and remaining differences, resolves the historical recipe or explicitly reviews its absence, and chooses a new protected-change candidate with native/vector gates. This proof can be reproduced locally with `fetch-source.py`, `fetch-perl-support.py`, `run-build-proof.py <abi> <new-attempt-number>`, and `analyze-build-proof.py`; commands must retain the repository's PowerShell7/UTF-8 convention. Do not overwrite the retained attempt numbers or infer a production-ready artifact from this record.
