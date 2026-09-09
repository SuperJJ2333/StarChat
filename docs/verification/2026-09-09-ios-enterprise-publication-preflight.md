# iOS enterprise release preflight and isolated update correction

User supplied `ChatFlow-0.3.69-build2073-enterprise.ipa` and requested iOS distribution/update prompts without changing Android. No website, release-setting or notification mutation has been made during preflight.

## Supplied package findings

59,506,530 bytes, SHA256 `fd0cab49952f28e1bdfe56f5008e063ea34ae3e84d0c46f47ee20753b1117bad`. App Info.plist is `com.liuhetong.liuhetongMobile`, 0.3.69/2073, minimum iOS16, with iPhone/iPad and audio/VoIP/remote-notification declarations. The published Android statistics resource hash is retained.

Both the embedded provisioning profile and Runner's signed XML entitlements identify `ZXB3TS7QD4.cn.edu.buaa.wxwork.notifyext`, which does not match the app Bundle ID. Profile expiry is 2026-12-03 and all-device provisioning is present, but those facts do not resolve the identity mismatch. Runner additionally loads `Frameworks/AppRuntime/ATHelper.dylib` and `Frameworks/Partner/libutils.dylib`, absent from the verified input. These were inspected as data, not executed. Static consistency checks do not establish a valid normal-device installation, working APNs or safe upgrade/key continuity. Certificate revocation/whole-package cryptographic verification is not claimed.

The provided app was compiled with `LIUHETONG_IN_APP_UPDATE=false` by the preceding iOS workflow. Consequently server configuration alone cannot activate its update dialog. The existing shared update endpoint does not distinguish platforms; pointing its settings at an IPA would affect Android. These findings block activation of the supplied file as the requested verified iOS release.

## Correction

New candidate: 0.3.70/2074, with iOS checks enabled. The client requests `platform=ios` and requires an explicit iOS response marker; a legacy server returning Android data is treated as unconfigured. iOS runtime build numbers retain their full integer rather than Android ABI normalization. The version name is incremented because existing update resolution uses semantic versions.

Backend iOS settings are separate from the existing five Android keys. Default/explicit Android projections preserve the existing shape and values; unconfigured iOS never falls back to Android. Invalid platforms fail HTTP validation, and authentication/audit behavior is preserved. The existing admin Android setting route is unchanged.

Client red evidence: missing iOS query, accepting an Android projection, and normalized iOS build. Green: 30 focused client tests, then all 1,562 Flutter tests and clean analyzer. Backend platform tests observed expected red failures before implementation; 22 focused backend/contract tests passed. Full repository and final build evidence are recorded after completion.

Specification review and subsequent quality/security review found no unresolved actionable findings. `scripts/verify.ps1` completed with `Verification: PASS`: backend/Worker 386 passed with 19 existing environment skips, mobile boundaries 66, infrastructure 17, push bridge 28 and Matrix bot 9. Migration/OpenAPI/UI drift, import/AST and Compose checks passed. Existing dependency deprecation warnings remain visible and were not suppressed.

Read-only production preflight observed Android 0.3.68/2072, URL `https://www.liuhetong888.com/downloads/ChatFlow-0.3.68-build2072-arm64.apk`, and settings snapshot digest `d6fb203a9151c4a474ab13cafe899615d4bf334976a70a627e2ddbe2645d5691`. Container/image remained the preceding deployment. No production database or web asset was changed.

## Required handoff

The corrected candidate must be signed for the actual Bundle ID with valid enterprise identity and compatible push/keychain entitlements, and tested as an upgrade before activating website/manifest/update settings. Do not inject unrelated libraries or change application identity as a shortcut. Old installed packages whose checks were compiled off require an initial manual website upgrade; a server-only popup cannot be promised for those versions.

Original supplied IPA and local technical inspection JSON remain under the primary workspace's `docs/verification/artifacts/2026-09-09/unified-mobile/`. New correction logs are under this worktree's `docs/verification/artifacts/2026-09-09/ios-enterprise-release/`. No keys, profiles, IPA files or raw technical artifacts are staged for Git.
