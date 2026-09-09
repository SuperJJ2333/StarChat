# iOS enterprise release preflight and isolated update correction

User supplied `ChatFlow-0.3.69-build2073-enterprise.ipa` and requested iOS distribution/update prompts without changing Android. No website, release-setting or notification mutation has been made during preflight.

## Supplied package findings

59,506,530 bytes, SHA256 `fd0cab49952f28e1bdfe56f5008e063ea34ae3e84d0c46f47ee20753b1117bad`. App Info.plist is `com.liuhetong.liuhetongMobile`, 0.3.69/2073, minimum iOS16, with iPhone/iPad and audio/VoIP/remote-notification declarations. The published Android statistics resource hash is retained.

Both the embedded provisioning profile and Runner's signed XML entitlements identify `ZXB3TS7QD4.cn.edu.buaa.wxwork.notifyext`, which does not match the app Bundle ID. Profile expiry is 2026-12-03 and all-device provisioning is present, but those facts do not resolve the identity mismatch. Runner additionally loads `Frameworks/AppRuntime/ATHelper.dylib` and `Frameworks/Partner/libutils.dylib`, absent from the verified input. These were inspected as data, not executed. Static consistency checks do not establish a valid normal-device installation, working APNs or safe upgrade/key continuity. Certificate revocation/whole-package cryptographic verification is not claimed.

The provided app was compiled with `LIUHETONG_IN_APP_UPDATE=false` by the preceding iOS workflow. Consequently server configuration alone cannot activate its update dialog. The existing shared update endpoint does not distinguish platforms; pointing its settings at an IPA would affect Android. These findings prevent claiming verified normal installation or server-activated in-app updates. The user subsequently declined obtaining a corrected signature; the unchanged 2073 website distribution is accepted as their requested scope, with these limitations retained.

## Correction

New candidate: 0.3.70/2074, with iOS checks enabled. The client requests `platform=ios` and requires an explicit iOS response marker; a legacy server returning Android data is treated as unconfigured. iOS runtime build numbers retain their full integer rather than Android ABI normalization. The version name is incremented because existing update resolution uses semantic versions.

Backend iOS settings are separate from the existing five Android keys. Default/explicit Android projections preserve the existing shape and values; unconfigured iOS never falls back to Android. Invalid platforms fail HTTP validation, and authentication/audit behavior is preserved. The existing admin Android setting route is unchanged.

Client red evidence: missing iOS query, accepting an Android projection, and normalized iOS build. Green: 30 focused client tests, then all 1,562 Flutter tests and clean analyzer. Backend platform tests observed expected red failures before implementation; 22 focused backend/contract tests passed. Full repository and final build evidence are recorded after completion.

Specification review and subsequent quality/security review found no unresolved actionable findings. `scripts/verify.ps1` completed with `Verification: PASS`: backend/Worker 386 passed with 19 existing environment skips, mobile boundaries 66, infrastructure 17, push bridge 28 and Matrix bot 9. Migration/OpenAPI/UI drift, import/AST and Compose checks passed. Existing dependency deprecation warnings remain visible and were not suppressed.

Read-only production preflight observed Android 0.3.68/2072, URL `https://www.liuhetong888.com/downloads/ChatFlow-0.3.68-build2072-arm64.apk`, and settings snapshot digest `d6fb203a9151c4a474ab13cafe899615d4bf334976a70a627e2ddbe2645d5691`. Container/image remained the preceding deployment. No production database or web asset was changed.

## Required handoff

The corrected candidate must be signed for the actual Bundle ID with valid enterprise identity and compatible push/keychain entitlements, and tested as an upgrade before activating website/manifest/update settings. Do not inject unrelated libraries or change application identity as a shortcut. Old installed packages whose checks were compiled off require an initial manual website upgrade; a server-only popup cannot be promised for those versions.

Original supplied IPA and local technical inspection JSON remain under the primary workspace's `docs/verification/artifacts/2026-09-09/unified-mobile/`. New correction logs are under this worktree's `docs/verification/artifacts/2026-09-09/ios-enterprise-release/`. No keys, profiles, IPA files or raw technical artifacts are staged for Git.


## Final website verification and Android recovery

The user answered “不需要” to the request for a matching signing identity. No further signing approval was imposed, and the supplied 2073 was not replaced by candidate 2074.

During this work a separate production publication made the exact supplied package available at `https://www.liuhetong888.com/downloads/ios/ChatFlow-0.3.69-2073-enterprise-fd0cab49.ipa`. This task did not duplicate or overwrite that publication. Public HTTPS downloads (TLS validation enabled, resolved directly to the origin) verified the entire IPA hash against the supplied file, the manifest bundle identifier/build/package URL, homepage 2073 entry and Safari installation link. The served QR image matches the generated QR matrix for `https://www.liuhetong888.com/download` exactly. Android APK links remain unchanged; the server ARM64 APK SHA256 is `0e68c73cd4531efc1c66283ca9261191adf3babd5c35250154c02bd2be347f16`.

A concurrent release operation had incorrectly written iOS2073 into the five shared Android update keys, audit trace `release-0.3.69-build2073-ios` at 2026-09-09 12:57 UTC. The live route still has no platform separation, so this would advertise an incorrect update to Android. This task restored the exact five pre-release values from their audit before-images using `SettingService.set_many`, with precondition checks and an exact match to the preflight snapshot digest. The new audit trace is `restore-android-2072-after-ios-shared-key-write-20260909`. Two subsequent reads confirmed SHA256 `d6fb203a9151c4a474ab13cafe899615d4bf334976a70a627e2ddbe2645d5691`: Android 0.3.68/2072 and its original APK URL/notes/minimum. No Android package was replaced.

The production API image `sha256:0751596a6a7e9a48b0f7f98f4e57b2fa3c9da8bb76ea48c49aa09bce2b34028c` belongs to concurrent Moments privacy work. It was preserved; the update-isolation candidate backend code was not deployed over it. The other active task confirmed it will not touch these update keys.

Candidate 0.3.70/2074 signed CI run 34353418769 succeeded for source `8bec689ee4d37d6a3c2a933f229870848763d0da`, and artifacts were retained locally. Native run 34353418855 remains in progress at this checkpoint; no completion claim is made. This candidate is not published or substituted for the user-selected enterprise IPA.

Result: website/manual distribution of the supplied 2073 is available and verified at the file/link level. In-app update popup activation remains unfulfilled because this installed binary compiled checks off. Actual device installation, enterprise signature validity, APNs and upgrade data continuity remain unverified for this supplied re-signing. No notification broadcast or shared Android-setting workaround was used.
