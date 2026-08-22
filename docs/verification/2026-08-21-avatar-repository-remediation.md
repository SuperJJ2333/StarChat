# 2026-08-21 Avatar and Repository Remediation Verification

## Root cause

1. `MatrixUserAvatar` deferred every `mxc://` resolution to `initState`, so a newly entered route built a default `UserAvatar` before `authenticatedMediaSupported()` returned. The visible default-to-remote transition was deterministic on each route recreation.
2. Main conversation rows used `room.getParticipants()` only. Matrix lazy-loaded membership can contain only the logged-in user until `requestParticipants([Membership.join])` completes; this produced a one-tile mosaic. The chat-information path did request members, but then also awaited per-member capability discovery, prolonging the incorrect first render.
3. Group rows ignored `m.room.avatar`; the code always rendered a mosaic, even if the group supplied its own room avatar.
4. The Matrix server advertises v1.11, so media is authenticated. The active client must carry the Bearer header with the `/_matrix/client/v1/media/thumbnail` request; a public `mxc://` URL cannot be handed directly to the ordinary cache image widget.
5. Server checks show business-api and Synapse healthy. Mobile Dart code ships inside the APK and is not a server-side deployment artifact. The server checkout has no `.git`, so it is a deployment tree rather than a synchronized Git checkout.

## Change

- `MatrixAvatarUrlResolver.resolveImmediately` builds the authenticated first-paint thumbnail request from the URI, homeserver and active token; later capability resolution remains cached verification.
- `MatrixUserAvatar` initializes from that immediate result, avoiding a default-avatar frame for a known custom Matrix avatar.
- `MatrixHomePage` requests joined members once per group and refreshes only the matching room mosaic when results arrive.
- Conversation and folded-group rows select the explicit Matrix `m.room.avatar` before falling back to member mosaics.
- `MatrixGroupChatInfoGateway` uses immediate URL metadata while retaining URI/client context for cells.
- Local worktrees/branches were archived in a Git bundle, removed, then local refs were reduced to `main`. No remote is configured.

## Evidence

| Check | Command | Result | Exit |
|---|---|---|---:|
| Red (member-load test first draft) | `flutter test test/features/matrix/group_chat_info_test.dart` | Test compilation exposed Matrix constructor mismatch; fixed before implementation verification | 1 |
| Green resolver | `flutter test test/features/matrix/avatar_url_resolver_test.dart` | `6` tests passed, including synchronous first-paint authenticated URL | 0 |
| Green members | `flutter test test/features/matrix/group_chat_info_test.dart` | `6` tests passed | 0 |
| Analyze | `flutter analyze --no-pub ...` | `No issues found!` | 0 |
| Focused regression | `flutter test test/features/matrix/avatar_url_resolver_test.dart test/features/matrix/group_chat_info_test.dart test/features/matrix/direct_chat_info_test.dart test/ui/wechat_components_test.dart` | `27` tests passed | 0 |
| Matrix external health | `Invoke-WebRequest https://liuhetong888.com/_matrix/client/versions` | HTTP `200`; includes `v1.11` | 0 |
| Business health | SSH container Python urllib request to `/api/v1/health/live` | `{"ok":true,"service":"畅聊 Business API"}` | 0 |
| Git before | `git branch -vv; git worktree list --porcelain` | `main` + four attached feature/fix branches + detached worktree | 0 |
| Git archive | `git bundle create docs/verification/artifacts/2026-08-21/branch-cleanup-backup.bundle --all` | bundle SHA-256 `E2D01FBABE01C1F1B32ED62A33DF1B96B856166FA2F2A680DC28E39E7D8B4B54` | 0 |
| Git after | `git for-each-ref --format='%(refname:short)' refs/heads refs/remotes; git worktree list --porcelain` | only `main`; only primary worktree; no remotes | 0 |

## Pending final package verification

Build the APK with the documented Dart defines, install it on `emulator-5554`, verify `MainActivity` is resumed, and append its APK hash/output below.

## Final package verification

| Check | Command | Result | Exit |
|---|---|---|---:|
| APK build | `C:\src\flutter\bin\flutter.bat build apk --debug --dart-define=LIUHETONG_BUSINESS_API_URL=https://liuhetong888.com --dart-define=LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888.com` | `Built build\\app\\outputs\\flutter-apk\\app-debug.apk` | 0 |
| APK digest | `Get-FileHash apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk -Algorithm SHA256` | `303CC4E3A4308E4FD4618790EDA03360EEBBEA3E263AF715B66A00CDEC9F3A7C` | 0 |
| Install/launch | `adb -s emulator-5554 install --no-streaming -r <apk>; adb -s emulator-5554 shell am force-stop com.liuhetong.mobile; adb -s emulator-5554 shell monkey -p com.liuhetong.mobile 1` | `Success`; `Events injected: 1` | 0 |
| Active package | `adb -s emulator-5554 shell pm path com.liuhetong.mobile; adb -s emulator-5554 shell dumpsys activity activities` | `package:/data/app/com.liuhetong.mobile-zJecAc0KGXOSco1Ukd_N1w==/base.apk`; `mResumedActivity: ... com.liuhetong.mobile/.MainActivity` | 0 |
| Full verification | `pwsh -NoProfile -File scripts/verify.ps1` | `Repository policy: PASS`; `169 passed, 1 skipped`; `Flutter boundary tests 19 passed`; `OpenAPI contract: PASS`; `Verification: PASS` | 0 |

## Matrix local-cache reset and re-login synchronization

| Check | Command | Result | Exit |
|---|---|---|---:|
| Stop and clear app data | `adb -s emulator-5554 shell am force-stop com.liuhetong.mobile; adb -s emulator-5554 shell pm clear com.liuhetong.mobile` | `Success`; removed the app-private Matrix SQLite/cache, Matrix session and local E2EE/device state together with business-session and avatar metadata caches | 0 |
| Re-launch clean app | `adb -s emulator-5554 logcat -c; adb -s emulator-5554 shell monkey -p com.liuhetong.mobile -c android.intent.category.LAUNCHER 1` | `Events injected: 1`; process PID `11056` started from a clean local state | 0 |
| Initial log check | `adb -s emulator-5554 logcat -d -v brief | Select-String 'M_FORBIDDEN|AvatarFirstPaint|GroupSync|GroupMembers|FATAL EXCEPTION'` | No `M_FORBIDDEN` or fatal exception emitted before login | 0 |

The application is now at its clean-login state. Enter the account credentials in the emulator to create a fresh Matrix session, then wait for initial synchronization before validating group members and avatars.

## Chat presentation remediation

| Check | Command | Result | Exit |
|---|---|---|---:|
| Red tests | `flutter test test\\ui\\group_avatar_mosaic_test.dart test\\features\\matrix\\room_page_presentation_test.dart` | Failed as intended: `gridDimensionForCount` and `groupRoomNavigationTitle` were absent | 1 |
| Green tests | `flutter test test\\ui\\group_avatar_mosaic_test.dart test\\features\\matrix\\room_page_presentation_test.dart test\\features\\matrix\\group_chat_info_test.dart` | `11` tests passed | 0 |
| Static analysis | `flutter analyze --no-pub lib\\ui\\chat\\group_avatar_mosaic.dart lib\\features\\matrix\\matrix_home_page.dart test\\ui\\group_avatar_mosaic_test.dart test\\features\\matrix\\room_page_presentation_test.dart` | `No issues found!` | 0 |
| Package and install | `flutter build apk --debug <documented defines>; adb -s emulator-5554 install --no-streaming -r build\\app\\outputs\\flutter-apk\\app-debug.apk` | Built and installed; SHA-256 `1CBC74DBCB233929E1BB27C86493069F8F332B7F9929EA465CF48563248B81AB` | 0 |
| Launch | `adb -s emulator-5554 shell monkey -p com.liuhetong.mobile -c android.intent.category.LAUNCHER 1; adb -s emulator-5554 shell dumpsys activity activities` | `com.liuhetong.mobile/.MainActivity` resumed | 0 |

Changed behavior: group mosaics use equal square cells in a 1x1, 2x2, or 3x3 grid and clip source avatars with `BoxFit.cover`; RoomPage navigation background is opaque `#F7F7F7` with automatic background changes and blur disabled; group titles use custom-name-or-`群聊` plus joined-member count and long names use `前8...后3(人数)`; an empty room message history renders a blank content area.

## Group announcement and fixed navigation verification

| Check | Command | Result | Exit |
|---|---|---|---:|
| Static analysis | `flutter analyze --no-pub lib` | `No issues found!` | 0 |
| Focused regression | `flutter test test\\features\\matrix\\group_chat_info_test.dart test\\features\\matrix\\room_page_presentation_test.dart test\\ui\\wechat_components_test.dart test\\ui\\group_avatar_mosaic_test.dart` | `28` tests passed | 0 |
| APK build | `flutter build apk --debug --dart-define=LIUHETONG_BUSINESS_API_URL=https://liuhetong888.com --dart-define=LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888.com` | Built `build\\app\\outputs\\flutter-apk\\app-debug.apk` | 0 |
| Install and launch | `adb -s emulator-5554 install --no-streaming -r <apk>; adb -s emulator-5554 shell monkey -p com.liuhetong.mobile -c android.intent.category.LAUNCHER 1` | `Success`; `com.liuhetong.mobile/.MainActivity` resumed | 0 |

APK SHA-256: `C996A3EC4417031AD81403ACEBA46F70996B5FBEC434CF822C19B39F74921013`.

The application now uses a globally fixed, opaque `#F7F7F7` Cupertino navigation background. Group announcements increment a room setting version when published. RoomPage compares that version with its per-device read version, shows a 40dp announcement bar only for unread announcements, opens the full announcement page, then persists the seen version and hides the bar until the next announcement version.

## 2026-08-22 群成员、标题与引用复核

- 根因：Matrix `createRoom(invite: ...)` 写入的是 `invite` membership；只有被邀请账号的 Matrix 客户端完成同步并执行 `joinRoom` 后才成为 `join` membership。创建者客户端不能代表其他账号确认加入。因此此前仅以 `Membership.join` 请求成员时，服务端返回只有创建者，群头像、聊天信息和标题人数均为 1。
- 改动：聊天信息同时读取 `join` 与 `invite` 成员，保留成员头像和昵称的数据源；成员格可点击，已映射通讯录成员打开对应 `ContactProfilePage`。群头像和导航标题的实际成员数仍严格使用 `join`，避免把待加入账号伪报为已入群。
- 改动：无自定义群名不再把成员昵称写为 Matrix room name；导航标题统一由 `groupRoomNavigationTitle` 生成 `群聊(人数)`。有名称时在“名称 + 人数”超过 20 个 Unicode grapheme clusters 时采用前 8、`...`、后 3、人数的中间省略格式。
- 改动：引用区与发出消息同侧右对齐，使用深色容器；点击引用会分批加载最多 20 页历史、定位到目标事件并 1.4 秒高亮。无法读取的目标不会无限请求。

| 验证 | 命令 | 结果 |
| --- | --- | --- |
| 定向测试 | `C:\src\flutter\bin\flutter.bat test test\features\matrix\group_chat_info_test.dart test\features\matrix\room_page_presentation_test.dart test\features\matrix\message_reminder_service_test.dart` | Exit 0，18 passed |
| 静态分析 | `C:\src\flutter\bin\flutter.bat analyze --no-pub lib\features\matrix\matrix_home_page.dart lib\features\matrix\group_chat_controller.dart lib\features\matrix\group_chat_info_controller.dart lib\features\matrix\group_chat_info_page.dart` | Exit 0，No issues found |
| 构建 | `C:\src\flutter\bin\flutter.bat build apk --debug --dart-define=LIUHETONG_BUSINESS_API_URL=https://liuhetong888.com --dart-define=LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888.com` | Exit 0，`build\app\outputs\flutter-apk\app-debug.apk` |
| 安装并启动 | `adb -s emulator-5554 install --no-streaming -r build\app\outputs\flutter-apk\app-debug.apk`; `adb -s emulator-5554 shell monkey -p com.liuhetong.mobile -c android.intent.category.LAUNCHER 1` | Exit 0，Success；PID `22170` |
| 安装身份 | `adb -s emulator-5554 shell dumpsys package com.liuhetong.mobile` | `lastUpdateTime=2026-08-22 21:20:06`；APK SHA-256 `74AB9DA1835EE81AD690365123FE7E080BA7026A8A7A96900F8FEE2EB574704F` |
