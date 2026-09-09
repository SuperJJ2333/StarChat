# Redmi account-switch repaired test build

Authorized by user to build, install and verify 10316dda on connected Redmi Note7 cbd0156b. Source is codex/mobile-parity-20260909 at 10316dda plus opt-in debug applicationIdSuffix configuration. This is a targeted login repair build, not a new formal Android release or website update.

Build: 0.3.76-debug/2080, standard, android-arm64, com.liuhetong.mobile.debug. Matrix homeserver, business API and Getui defines all https://liuhetong888.com. Initial online Gradle dependency TLS wait was stopped; the same Gradle arguments completed offline using installed cache. No dependencies or application logic changed for this retry.

Apktool 2.12.1 full decode/rebuild; build-tools 36.0.0 zipalign -P 16 and fixed signing certificate 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff. Re-decode verification preserves 26,537 classes, 338 native/assets entries and manifest semantics. Source and final debug ARM64 checks passed, and source kernel includes _freshLoginAfterClear. Final SHA256 ec9bbfbe6e9c108ecfff475c72dcb7429fe5fd71980161a94c0176218e088572.

Installed package com.liuhetong.mobile.debug was 2079 with the same fixed signer; adb install -r returned Success and package manager now reports 0.3.76-debug/2080, updated 2026-09-10 06:01:13. Launched MainActivity and identified PID 30711. The separate com.liuhetong.mobile 2077 has a different signer and was not modified. No uninstall or adb data-clear operation performed.

Device account-switch outcome pending user credential entry/confirmation. Safe log collector only retains predefined technical markers and timestamps, no raw logs or credentials. Installation and running PID do not prove successful login.
Additional mobile boundary tests: 66 passed. git diff --check passed. Post-install PID remains alive; a generic PlatformException marker alone is not evidence of the login failure or its cause. Account-switch result remains pending.
