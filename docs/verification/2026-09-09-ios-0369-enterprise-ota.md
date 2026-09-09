# iOS 0.3.69 (2073) enterprise OTA publication and update popup

Date: 2026-09-09. Follows `docs/verification/artifacts/2026-09-09/unified-mobile/release-report.md`, whose distribution boundary awaited exactly this externally signed enterprise IPA. The user supplied `ChatFlow-0.3.69-build2073-enterprise.ipa` (59,506,530 bytes) and asked for the iOS update popup to be pushed with a working download path.

## Pre-publication IPA validation

`enterprise-ipa-inspection.json` (script: `inspect_enterprise_ipa.py`) — all checks passed:

- Identity: bundle `com.liuhetong.liuhetongMobile`, version `0.3.69`, build `2073`, MinimumOSVersion 16.0, background modes `audio`/`voip`/`remote-notification` — matches `enterprise-signing-handoff.md`.
- Provisioning: enterprise profile `20260107buaawxworklocalNOTI`, team `ZXB3TS7QD4` (Beihang University), `ProvisionsAllDevices`, no device list, expires 2026-12-03 02:06:44; `aps-environment=production`, `get-task-allow=false`.
- Statistics HTML asset inside the IPA matches the published Android bytes: SHA256 `89eab23270dc87ce6fd07715d9abb2606455d94ce1fc16cd56d2deeaeeafb9d5` (the hash gate added after the CRLF incident).
- SQLCipher framework present; `_CodeSignature/CodeResources` present.
- Resource parity vs the App Store re-sign input: 482 identical entries; only native binaries differ (expected — re-signing rewrites embedded signatures); the signing service added `Frameworks/AppRuntime/ATHelper.dylib`, `Frameworks/Partner/libutils.dylib` (both LC_LOAD_DYLIB-linked from the main binary) and a `flag` marker. The previously published 0.3.53 (42d30a18) enterprise package contains the exact same three entries with the same linkage, so this is the signing service's consistent output, not a new injection. The profile's `application-identifier` (`ZXB3TS7QD4.cn.edu.buaa.wxwork.notifyext`) does not textually match the Info.plist bundle id — the identical pattern shipped in the published 0.3.53 package. Recorded as a known property of this signing channel.

Not established here: on-device overwrite installation, upgrade data continuity, live push/CallKit. These require an installed device (same limitation recorded on 2026-09-08).

## Deployment (www.liuhetong888.com)

- Uploaded via 4×16 MB chunked transfer with per-chunk SHA256 checks and a merged-file SHA256 gate (`fd0cab49952f28e1bdfe56f5008e063ea34ae3e84d0c46f47ee20753b1117bad`) before install. Live at `/downloads/ios/ChatFlow-0.3.69-2073-enterprise-fd0cab49.ipa` (immutable versioned name); the 0.3.53 package is retained for rollback.
- `manifest.plist` replaced: software-package URL points to the new versioned IPA, bundle-version `2073`, same bundle id/title as before. Byte-identical copy staged at `ios-distribution/manifest.plist`.
- `/download` page updated: version line `0.3.69（2073） · 60 MB`, IPA file link. Homepage `/src/admin-home.js` iOS entry labels updated (3 strings). Repo sources `frontend/download.html`, `frontend/src/admin-home.js` updated identically (diff against live copies showed only these lines); `frontend/tests/home-ios-download.test.mjs` expectation updated to `0.3.69（2073）` and passes. QR code targets the page URL and needed no change.
- Backups for rollback: `/opt/starchat/docs/verification/artifacts/2026-09-09/unified-mobile/backup-20260909T124622Z/` (previous manifest.plist, download.html, src/admin-home.js). No nginx config change was needed; `nginx -t` inside `starchat-gateway-1` is clean.

## Update popup configuration

Published via the app's own `SettingService` inside `starchat-business-api-1` (same path as 0.3.45/0.3.68 releases; produces the admin-API-identical audit trail without minting an admin JWT). `publish-output.txt` has full before/after; script: `ios-distribution/publish_app_update_settings.py`.

| key | before | after |
|---|---|---|
| app_latest_version | 0.3.68 | 0.3.69 |
| app_latest_build | 2072 | 2073 |
| app_min_supported_build | 3 | 3 (unchanged, dialog dismissible) |
| app_update_notes | 0.3.68 文案 | 0.3.69 文案 |
| app_apk_url | …/ChatFlow-0.3.68-build2072-arm64.apk | https://www.liuhetong888.com/download |

`app_apk_url` deliberately points to the platform-aware download page, not an `itms-services://` URL: the settings row is shared by Android and iOS clients, and a scheme URL would break the Android 更新 button until the 0.3.69 Android build is published. iOS users tapping 更新 open the page whose primary button triggers the system install prompt; Android users keep a working APK download. Per-platform URLs would be a small follow-up (API/contract change).

Audit: 5 × `settings.update` / `app_setting` / `SUCCESS` under `trace_id=release-0.3.69-build2073-ios`, actor `release-deploy`, with before/after values (`publish-output.txt`).

## Popup math

- iOS installed base 0.3.53 (build 59): `0.3.69 > 0.3.53` semantic compare → dialog shows; 更新 opens the download page → 安装 iOS 测试版 → system install.
- Android installed base 0.3.68 (build 2072): dialog shows with the same working page (APK panel).
- Clients already on 0.3.69/2073: no dialog. `min_supported_build` stays 3, so nothing is forced.

## Public verification

`ios-distribution/public-verification.txt`: manifest 200 `application/xml` `no-store`, byte-identical to local from both server and workstation; IPA 200 `application/octet-stream` with `Accept-Ranges` (206 on a range probe); old IPA still 200; `/download` and homepage labels live; `GET /api/v1/app-updates/latest` answers 401 `AUTH_REQUIRED` without a token (route alive, settings read-back verified above).

## Incident record

The first chunk round was deleted by a concurrent `rm /tmp/ipa-chunk-*` cleanup command issued while uploads were still running (operational mistake, no user impact — nothing had been published yet). Chunks were re-uploaded; installation proceeded only after all per-chunk and merged SHA256 values matched.

## Status

Website publication and popup configuration are live and verified at the URL/response level. Device-level install/upgrade continuity, live push and CallKit remain user-device checks, consistent with the 09-08 record. Android 0.3.69/2073 publication is the next step of the agreed release order and is not part of this entry.
