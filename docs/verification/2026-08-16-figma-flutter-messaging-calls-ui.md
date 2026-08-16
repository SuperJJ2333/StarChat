# 畅聊 Figma → Flutter 消息、聊天与通话验证证据

**日期：** 2026-08-16  
**分支：** `feature/figma-messaging-calls-ui`  
**Figma：** [畅聊 HTML → Figma 移动端设计系统](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78)

## Figma 设计来源

- 消息列表：`messages-inbox-default`，节点 `30:2`，393×852。
- 混合聊天：`chat-room-mixed`，节点 `30:31`，393×852。
- 语音通话已连接：`calls-audio-connected`，节点 `29:996`，393×852。
- 通话状态全集位于页面 `30 Calls`，节点 `19:2`；本阶段同时核对了来电、视频连接、静音和权限状态的元数据。
- `get_design_context` 均按 `figma-design-to-code` 流程读取；返回的 React/Tailwind 只作为布局和视觉参考，代码已映射为项目现有 Flutter/Cupertino 组件。

## Red 证据

静态设计契约首次运行：

```powershell
$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'
python -m pytest tests/mobile/test_figma_ui_contract.py -q
```

- 结果：5 项通过、2 项失败。
- 预期失败原因：`ConversationListTile`、`ChatComposerBar`、`CallControlButton` 文件不存在，会话/Composer/通话 Token 与语义图标尚未建立。

Flutter 展示组件首次运行：

```powershell
C:\src\flutter\bin\flutter.bat test test/ui/messaging_surfaces_test.dart
```

- 结果：编译失败。
- 预期失败原因：三个新组件和 `ChangliaoIcons.muted` 尚不存在。
- 测试自身的 Dart collection 语法修正后再次执行，失败仅剩缺少组件/图标，确认 Red 有效。

CallPage 首次运行：

```powershell
C:\src\flutter\bin\flutter.bat test test/features/matrix/call_page_test.dart
```

- 结果：3 项失败。
- 预期失败原因：原页面没有“周然 · 语音通话 / 视频通话”“畅聊加密来电”“端到端加密”和稳定通话控件 Key。

## Green 与实现结果

- `ConversationListTile` 固定为 Leading / Body / Trailing，使用 48px 头像、72px 最小行高、最后消息、时间、真实未读数、`99+` 和静音状态。
- `MatrixHomePage` 继续读取真实 `MatrixSdkE2eeClient.rooms`、`Room.lastEvent`、`notificationCount` 和 `pushRuleState`，没有引入演示会话数据；同步按钮继续调用真实 Matrix sync。
- `ChatComposerBar` 固定为附件、语音、文本、发送四个插槽，每个交互至少 44px；回调继续进入现有 `MediaMessageService`、`VoiceComposer` 和 `RoomTimelineController`。
- `RoomPage` 保留真实时间线加载、已读、发送中/失败/已发送、媒体和语音流程；从 Business API 联系人入口打开时，语音/视频图标调用既有真实通话回调。
- `CallControlButton` 使用真实 Cupertino 图标、72px 圆形控件、可见文字和 Semantics；没有 Unicode/Emoji 伪图标。
- `CallPage` 保留现有 `CallController`、`MatrixCallBackend`、`RTCVideoRenderer` 和 WebRTC stream；仅替换通话表面，覆盖来电、等待、连接、静音、扬声器、镜头切换、权限失败、结束和关闭。
- 无媒体 backend 的页面不再向未初始化 renderer 写入 stream，Widget 测试和纯语音无渲染场景稳定通过。

Focused Green：

```powershell
C:\src\flutter\bin\flutter.bat test test/ui/messaging_surfaces_test.dart
C:\src\flutter\bin\flutter.bat test test/features/matrix/call_page_test.dart test/features/matrix/call_controller_test.dart
python -m pytest tests/mobile/test_figma_ui_contract.py tests/mobile/test_flutter_boundaries.py -q
```

- 展示组件：5/5 通过。
- CallPage + CallController：7/7 通过。
- 静态契约：13/13 通过。

## 完整自动化验证

```powershell
C:\src\flutter\bin\dart.bat format --output=none --set-exit-if-changed <本阶段 10 个 Dart 文件>
```

- 10 个文件，0 项需要格式化。

```powershell
C:\src\flutter\bin\flutter.bat analyze
C:\src\flutter\bin\flutter.bat test
```

- `No issues found`。
- Flutter 91/91 通过，较基线新增 8 项。

```powershell
pwsh.exe -NoProfile -File scripts/verify.ps1
```

- 工作树首次运行因 `.env` 是被忽略的本机配置、不会随 worktree 创建而失败；没有读取或记录其内容。
- 将主检出中被 `.gitignore` 排除的本机 `.env` 复制到隔离工作树后重新运行，退出码 0。
- Repository、Deployment、Template、Render、Migrations、OpenAPI、Docker 全部 PASS。
- Matrix Bot 9 项通过。
- Business API/Worker 161 项通过、1 项跳过。
- Flutter boundary 16 项通过。

## 规格符合性审查

- Figma 节点、393px 几何、Light/Dark Token、真实图标、空态、未读、静音、Composer 和通话状态均有代码或测试映射。
- 用户可见品牌继续使用“畅聊”；内部 `liuhetong_mobile`、类名、包名、Matrix ID 和历史技术标识未改。
- 新组件均使用语义名称与稳定 Key；页面没有复制 Matrix/Call 状态机，也没有硬编码虚构房间、消息或联系人。
- 音视频入口只在已有 Business 联系人上下文中启用，未从 Matrix 昵称推导业务身份。

## 质量与安全审查

- 未修改 Business API、OpenAPI、数据库迁移、账本、红包、钱包或任何金融状态。
- 未修改 Matrix E2EE、信令协议、房间安全校验、权限网关或媒体加密边界。
- 未引入外链设计资产、第三方 UI/图标依赖、密钥、Token、真实地址或敏感日志。
- 消息正文仍只在客户端从已解密的 Matrix 时间线渲染；没有发送到 Business API、日志、推送或分析系统。
- 通话操作仍通过现有 `CallController`，没有直接操作信令或绕过加密双人房间检查。
