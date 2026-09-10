# Runbook: Mobile app release deployment (Android APK / iOS enterprise OTA)

Scope: publishing a mobile release to `www.liuhetong888.com` and publishing the in-app update popup via the business API. Proven by the 0.3.69 iOS release (`docs/verification/2026-09-09-ios-0369-enterprise-ota.md`) and the 0.3.73 Android release (`docs/verification/2026-09-10-android-0373-2077-release.md`). Read together with `docs/runbooks/android-apk-rebuild.md` for packaging gates.

Server: `root@207.56.8.8`, SSH port `23421`. Containers: `starchat-gateway-1` (nginx), `starchat-business-api-1`, `starchat-business-postgres-1`. Web root: `/opt/starchat/frontend/`.

## 1. Artifact gates (before any upload)

- Identity check against the release handoff: bundle id / versionName / versionCode / build, min OS, background modes, entitlements, profile expiry (`ProvisionsAllDevices` and no device list for enterprise iOS).
- Content gates: statistics HTML hash must equal the published Android bytes; SQLCipher present; no unexpected extra native libraries versus the previously published package of the same signing channel.
- Hash baseline: compute the artifact SHA256 locally and carry it through every later step as the install gate.

## 2. Network routes (check in this order)

The workstation's default SSH route runs through the local proxy (`127.0.0.1:7897`). It can degrade to "TCP connects but SSH banner times out" for hours.

1. Diagnose: `ssh -v -p 23421 root@207.56.8.8 true` — "banner exchange timeout" with a successful `Test-NetConnection -Port 23421` means the route is degraded, not the server.
2. **Fallback route (use this)**: `ssh -J jumper -p 23421 root@207.56.8.8` (jump host `8.163.93.151`, configured in `~/.ssh/config`). It is independent of the local proxy, typically faster (~700KB/s vs ~100KB/s), and is the proven route for large uploads.
3. Do NOT improvise with third-party proxy subscriptions mid-incident. The 2026-09-10 HK subscription was diagnosed dead (inconsistent cross-resolver DNS, websocket backends not answering) — validating a stranger's node pool costs more time than the jumper route. If the default route is broken, report it and continue on the jumper.

## 3. Large-file upload procedure (APK/IPA)

History: two incidents shaped this procedure — a concurrent `rm /tmp/chunk-*` deleted an in-flight upload round (2026-09-09), and single-stream scp over the proxy route stalled repeatedly.

1. Split locally into 16 MB chunks (Python, temp dir outside the repository).
2. Upload with a resumable, sequential script (poll remote size per chunk, append `tail -c +N | ssh cat >>`, retry with backoff). Sequential single-stream over the jumper route beat 4-way parallel scp over the proxy; do not run cleanup commands (`rm /tmp/...`) while any upload is running.
3. Merge on the server **behind a SHA256 gate**: compare the merged file hash to the local baseline; on mismatch, stop — never install an unverified merge.
4. Install with `install -m 0644` to a versioned, immutable filename (`ChatFlow-<ver>-<build>-arm64.apk`, `ChatFlow-<ver>-<build>-enterprise-<sha8>.ipa`). Keep the previous release file in place. For Android, update the `latest-<abi>.apk` symlinks only for ABIs actually shipped.

## 4. iOS enterprise OTA specifics

- `manifest.plist` at `/downloads/ios/manifest.plist` (served as `application/xml`, `no-store`): software-package URL must be the new versioned IPA; `bundle-identifier` unchanged; `bundle-version` = CFBundleVersion (build number). Stage as `.new` and swap only after the IPA is installed.
- The download page (`/download`) and homepage labels live in the repo (`frontend/download.html`, `frontend/src/admin-home.js`) and are served as plain files from `/opt/starchat/frontend/`; diff server copies against the updated repo copies before overwriting to catch server-side drift. The QR code encodes the page URL, so it survives manifest changes.
- nginx config rarely changes; verify with `docker exec starchat-gateway-1 nginx -t` (nginx is not installed on the host).

## 5. Publishing the update popup (app-update settings)

Settings are single global rows shared by Android and iOS clients (`app_latest_version`, `app_latest_build`, `app_min_supported_build`, `app_update_notes`, `app_apk_url`), exposed at `GET /api/v1/app-updates/latest` (auth required).

- Publish with the app's own `SettingService` inside the business-api container (same audit trail as the admin API without minting an admin JWT):
  `docker exec -i -e PYTHONUTF8=1 -w /opt/business-api starchat-business-api-1 python3 - < publish_script.py <inspect|apply|rollback>`
  Use the inspect → apply pattern with a preflight backup, an audit-count assertion, and an endpoint projection check (see `docs/verification/artifacts/2026-09-10/android-release-2077-distribution/publish_settings_2077_pageurl.py`).
- Since the 2026-09-10 platform-aware endpoint deployment (commit `8bec689e`,
  image `starchat-business-api:app-update-platform-20260910`; see
  `docs/verification/2026-09-10-mobile-0380-2084-release.md`), the five
  legacy keys feed Android clients and the five `app_ios_*` keys
  (`app_ios_latest_version/build/min_supported_build/update_notes/download_url`)
  feed iOS clients; the response carries `platform: "ios"` so legacy servers
  are rejected by new clients. Publish each platform in its own `set_many`
  with its own audit trace.
- **Platform paths differ on purpose**: the Android `app_apk_url` may point at
  the immutable versioned APK (0.3.80+ convention), while
  `app_ios_download_url` must stay the download page
  (`https://www.liuhetong888.com/download`) — its primary button triggers the
  `itms-services://` install; a scheme URL in the setting would break the
  iOS 更新 button. Before the endpoint was platform-aware, both platforms read
  the same rows, so `app_apk_url` had to be the download page then; that
  constraint is gone.
- Publish the iOS keys **only after** the enterprise-signed IPA is installed
  and `manifest.plist` points at it; an early publication would show iOS users
  an update dialog for a package that cannot install yet.
- `app_update_notes` ≤ 255 characters (DB column is VARCHAR(255) while the admin API contract allows 2000 — known mismatch, do not exceed 255 until it is fixed).
- `min_supported_build`: only raise with explicit product approval; it turns the dialog into an unclosable barrier.
- Popup math: the client compares `latest_version` semantically against its own version name first (build number fallback). One global latest therefore targets both platforms at once — expect the dialog on every platform below latest.

## 6. Verification checklist (all URL checks from the server AND the workstation)

- New artifact: 200, correct MIME (`application/octet-stream` APK / `application/xml` plist), `Accept-Ranges` present (probe with a Range request → 206).
- `latest-<abi>.apk` resolves to the new build; previous release artifact still 200 (rollback path).
- `/download` and homepage show the new version labels; iOS manifest byte-compares to the staged copy.
- `GET /api/v1/app-updates/latest` without token → 401 `AUTH_REQUIRED` (route alive); settings read-back equals the published payload; audit rows exist for the trace id.
- Frontend tests covering changed page code pass (`node --test frontend/tests/home-ios-download.test.mjs` or equivalent).

## 7. Rollback

- Static files: reinstall the retained previous artifact, revert `manifest.plist`/pages from the deployment backup (`/opt/starchat/docs/verification/artifacts/<date>/.../backup-<ts>/`), re-point symlinks.
- Settings: run the publish script's `rollback` mode (restores the preflight backup, writes its own audit events under `<trace>-rollback`).

## 8. Repository hygiene for compose files

Overlay compose files live in `infra/compose/` (tron-watch, wallet-chain, wallet-manual, wallet-release, wallet-rollback). `docker-compose.yml` and `docker-compose.production.yml` stay at the repository root (deployment policy test and tooling assume root paths); `analysis_options.yaml` is Dart analyzer config, not deployment. Tests in `tests/infra/` (part of `scripts/verify.ps1`) assert these paths — update references together with any move, never archive or delete a compose file without checking `tests/infra/`, `docs/runbooks/`, and `Test-DeploymentPolicy.ps1` first.

## 9. Matrix framework releases (server only)

For the approved media deduplication and sync-worker rollout, use the procedure in
[matrix-framework-deployment.md](matrix-framework-deployment.md). Publishing this
server framework does not publish an APK/IPA or change the global update settings.
The SSH, SHA-256, backup and verification requirements above still apply.

Do not replace the entire production Compose file or re-render the entire gateway
from a local checkout without comparing it with the running deployment. The
2026-09-10 preflight found a production-only `/ios-call/` route that a blind render
would remove. `scripts/prepare_matrix_release.py` stages only the approved Matrix
changes while preserving existing services and gateway routes.

## 10. Wallet reserve-monitor backend releases

For the 2026-09-10 bounded stale-snapshot repair, use
[wallet-reserve-resampling-deployment.md](wallet-reserve-resampling-deployment.md).
Preserve the running API and Worker configurations independently; their images,
Compose layers and Python import paths can differ. This release changes no mobile
artifact, app-update setting, schema or administrator recovery state.

Backend URL checks use `https://liuhetong888.com`, including readiness JSON and
the unauthenticated 401 check. The `www` host serves static pages and can return
HTML 200 for these paths; status alone is not an API health proof.

## 11. Admin console readability releases

For the 2026-09-10 admin UI and read-only reporting update, follow
[admin-readability-deployment.md](admin-readability-deployment.md).
Release only the listed static files and the API reporting overlay. Preserve the
running API configuration, existing Worker, gateway routes, mobile downloads and
app-update settings. Database backup/isolated restore, SHA256 and candidate/rollback
configuration checks precede the API switch. This release adds no migration.

## 12. Wallet page verification releases

For the separately approved 60-minute wallet access verification, follow
[wallet-access-deployment.md](wallet-access-deployment.md). This changes the wallet
verification scope, not the global administrator login duration. Use the isolated
expand migration `0062_wallet_access_grant`, matching migration/rehearsal evidence,
and the API-only rollback; do not apply unrelated local migration heads.
