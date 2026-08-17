# Figma 根列表与通讯录索引验证证据

**日期：** 2026-08-18  
**规格：** `docs/superpowers/specs/2026-08-18-figma-root-list-parity-design.md`

## Figma 原始节点证据

- `34:80 / contacts-index-default`：页面背景 `#EDEDED`、顶部导航 `#F7F7F7`、内容行 `#FFFFFF`、头像为圆角矩形。
- `34:80` 当前连接版本的索引为 `A-Z, #`；本轮以用户最新明确要求为最高优先级，补充为 `★, A-Z, #`。
- 消息与发现继续使用其原始页面节点，通过同一 `surface/elevated` 语义 Token 落地白色内容行。

## Test-first 证据

红灯命令：

```powershell
flutter test test/ui/messaging_surfaces_test.dart test/features/contacts/contact_flow_test.dart
```

预期失败已观察：缺少 `starred`、`ContactIndex`、`conversation-elevated-surface`，证明测试覆盖旧实现缺口，而不是偶然失败。

绿灯结果：focused tests 全部通过。

## 自动验证

- `flutter analyze`：`No issues found!`
- `flutter test`：`169 tests passed`
- `pwsh -NoProfile -File scripts/verify.ps1`：`Verification: PASS`
  - Matrix Bot：9 passed
  - Business API / Worker：161 passed，1 skipped
  - Flutter boundary：19 passed
  - migrations / OpenAPI / Docker Compose：PASS

## APK 与雷电模拟器

- APK：`apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk`
- 大小：241,907,349 bytes
- 设备：`emulator-5554`
- 安装：`adb push` 后 `pm install -r` 返回 `Success`
- 包名：`com.liuhetong.mobile`
- `lastUpdateTime=2026-08-18 04:59:58`

构建成功；Flutter 同时报告若干三方插件仍使用传统 Kotlin Gradle Plugin 的未来兼容性提示，不影响本次 APK 生成或安装，后续依赖升级阶段处理。

截图：

- `docs/verification/2026-08-18-figma-root-list-parity-emulator.png`
  - 消息导航 `#F7F7F7`、会话行 `#FFFFFF`、圆角矩形头像、页面背景 `#EDEDED`。
- `docs/verification/2026-08-18-figma-contacts-index-emulator.png`
  - 通讯录白色入口/联系人行、`★ + A-Z + #` 右侧索引和字母分组。
- `docs/verification/2026-08-18-figma-discovery-surface-emulator.png`
  - 发现白色入口行、`#F7F7F7` 导航与 `#EDEDED` 页面背景。

## 规格符合性与质量审查

- 颜色均通过语义 Token 解析，未给页面增加私有覆盖样式。
- `UserAvatar` 的网络图片、错误占位和文字占位共享 `ClipRRect`。
- 星标、A-Z 和 # 分组不改变业务权威数据，不涉及 Matrix、E2EE 或资金域。
- 右侧索引在 393×852 基线和雷电模拟器 360 logical px 宽度均无 overflow。
