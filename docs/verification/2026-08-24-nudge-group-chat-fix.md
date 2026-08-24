# 2026-08-24 拍一拍与发起群聊修复验证

## 变更

- `NudgePreferenceService`、拍一拍设置页和 `PATCH /api/v1/profile/me` 统一限制自定义文案为 **10 个 Unicode 字符**。
- 发送事件的 `suffix` 从被拍对象的权威 profile 读取：A 设置“好运就到了”时，任意发送者拍 A 渲染为“{发送者昵称}拍了拍{A 昵称}好运就到了”；A 拍未设置文案的 B 渲染为“{A 昵称}拍了拍{B 昵称}”。
- 移除了私聊聊天信息页独立的 `DirectGroupMemberPickerPage`。私聊添加按钮现在回调至与通讯录更多菜单相同的 `AppHome._createGroupChat → GroupChatController → GroupChatPage` 路径，因此界面、布局、联系人选择、交互和建群流程完全一致。

## 定向验证

- RED：修复前 `flutter test test/features/matrix/nudge_service_test.dart test/features/matrix/group_chat_controller_test.dart` 的新增 11 字符断言失败，错误仍显示“不能超过 30 个字符”。
- GREEN：`C:\src\flutter\bin\flutter.bat test test/features/matrix/nudge_service_test.dart test/features/matrix/group_chat_controller_test.dart` — 7 passed。
- 后端：`py -3.12 -m pytest tests/business_api/identity/test_profile_api.py -q` — 13 passed；11 字符请求返回 422。
- 契约：`py -3.12 scripts/export_openapi.py` 与 `py -3.12 scripts/export_openapi.py --check` — PASS；`nudge_suffix.maxLength=10`。
- 静态检查：`flutter analyze` 无 error；有 3 条既有 contacts info 与 2 条既有测试 warning。

## Figma UI Review

- **Figma file / export ledger:** `design-demo/artifacts/figma-state.json`
- **Reviewed nodes/pages:** 消息/聊天 `18:7`，通讯录/好友 `19:3`
- **Components/states:** `app-nudge-notice`、发起群聊入口；default / pressed / disabled / loading / error / empty
- **Token and layout result:** PASS — 已有透明居中拍一拍 notice 与同一 GroupChatPage 路由复用，无新增 token。
- **Registry:** `packages/ui-contracts/changliao-component-registry.json` 的 `nudge-notice`（Figma key `18:7`）。
- **Figma URL:** https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78/%E7%95%85%E8%81%8A-%C2%B7-HTML-%E2%86%92-Figma-%E8%AE%BE%E8%AE%A1%E7%B3%BB%E7%BB%9F?node-id=18-7

## 公网与安装

- 已同步 `services/business-api/app/api/profile.py`、`services/business-api/app/modules/identity/profile.py` 及 OpenAPI 到 `/opt/starchat`，并重建、强制重建 `business-api` / `business-worker`。
- `public-health.txt`：公网健康检查 HTTP 200。
- 重新构建 `apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk`，SHA-256 `d86a722b2dd7321d5aa8071defcfe386a26bc019d21886cd5ed5fc1a5d280072`。
- 同一 APK 已安装到 `emulator-5554` 和 `emulator-5556`；两个设备回读 SHA-256 均匹配（见 `artifacts/2026-08-24/nudge-profile-deploy/installed-apk-hashes.txt`）。
