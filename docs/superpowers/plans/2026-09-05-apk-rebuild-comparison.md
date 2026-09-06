# 0.3.40 APK rebuild diagnostic

User explicitly requests an independently signed, rebuilt 0.3.40 artifact after reviewing the Android Modifier sample. This supersedes the earlier source-only packaging preference for this diagnostic artifact only.

Owner: root. Owned files: this plan and docs/verification/artifacts/2026-09-05/apk-rebuild-test/. No source or production changes.

1. Use pinned upstream Apktool for conventional decode/rebuild of the existing verified official ARM64 APK, reassembling DEX and resources. Preserve class and method content and application manifest semantics; do not introduce arbitrary padding, empty DEX, random strings or weakened settings from the sample.
2. Align APK, sign with the existing isolated local diagnostic key. Production signing key and update channel remain unchanged.
3. Verify package/version/ABI, permissions, normalized manifest, native/Flutter assets, class inventory and re-decoded smali. Store hashes and tool logs. User performs device installation and scanner test; no claim of scanner clearance.
4. Deliver standalone APK with clear diagnostic identity and signature compatibility limits. No uninstall, deployment, database or E2EE changes.
