# 0.3.40 ARM64 conventional rebuild diagnostic

User requested a rebuilt/re-signed 0.3.40 test artifact after reviewing the accepted Android Modifier sample. Approved bounded plan: `docs/superpowers/plans/2026-09-05-apk-rebuild-comparison.md`.

Input: official 0.3.40 ARM64, SHA256 `40b9617f382a358bb9cfdc43d3314a14f9086585522f81227bce11f52bac7463`.
Output: `artifacts/2026-09-05/apk-rebuild-test/ChatFlow-0.3.40-arm64-rebuilt-test.apk`.
Output SHA256: `386fe5980de5de4d8bcebf52559af80e5d7e6ad91b8e3675074015af1ec3c448`.
Size: 75,273,156 bytes. Package com.liuhetong.mobile, version 0.3.40, versionCode 2043, ARM64 only.

## Method

Pinned upstream Apktool 2.12.1 downloaded from the official GitHub release. Conventional full decode/build reassembles all five DEX files, recompiles resources and binary manifest. No manual smali edits, class relocation, extra empty DEX, random padding or HTML comments were added. Resource paths/table change through conventional resource rebuilding. Original manifest settings were retained instead of copying unrelated task/storage changes from the sample. No packer or code obfuscation added.

Aligned with Android build-tools 36.0.0 zipalign (`-P 16`, four-byte ZIP alignment), then signed with the existing isolated local diagnostic RSA 3072 key, separate from the production key. Certificate SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`. This reuses the earlier signature-only diagnostic identity to keep signing identity consistent across those two comparison artifacts.

## Verification and review

- Decode, build, signing, re-decode all exited zero; apksigner verifies v2/v3; post-sign zipalign check passed.
- Aapt confirms package/version/ARM64. Normalized full manifest dump is identical, including permissions/component settings.
- All 331 original native-library/asset entries match byte-for-byte, including Flutter business library and assets.
- 24,570 classes remain. Re-decoded smali initially differed in 36 classes only because the assembler omits explicit static default values. After narrowly normalizing static Z=false, I=0 and reference=null declarations, every class's full smali text matches, including method bodies. Raw differences retained in smali.diff. No APK mutation was needed to resolve this comparison.
- All five DEX hashes and resources.arsc differ, proving this artifact does more than signing. ZIP entries change from 986 to 989 with signing metadata.
- Specification review: requested version/rebuild/independent signature delivered; no product logic or production channel changed. Quality review: full smali/native/assets and manifest comparisons pass, signing verified, private key remains outside repository.
- No source change, device uninstall, production deployment or scanner upload. Repository application tests were not rerun because this task changes no source; artifact-specific checks are the relevant evidence. Device installation/scanner verdict and runtime end-to-end validation remain for the user's test.

This is a conventional rebuild diagnostic, not an exact replication of the Android Modifier algorithm or a promise of antivirus clearance. Different production/test certificates normally prevent in-place update of the official installation. Do not automatically uninstall or migrate user data.

Tool provenance: https://apktool.org/blog/apktool-2.12.1/ and https://github.com/iBotPeaches/Apktool/releases/download/v2.12.1/apktool_2.12.1.jar .
