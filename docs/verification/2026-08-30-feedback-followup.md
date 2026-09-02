# 用户反馈跟进：语音交互确认 + 发送视觉 + 版本号修复（2026-08-30）

发布：**0.3.10+13**。

## 1. “按住说话”点击无反馈的排查结论

**发布包含新代码已实证**：解包 0.3.9 arm64 APK 的 Dart AOT 快照，UTF-16LE 检索到 `松开手指，取消发送`/`按住说话`/`composer-keyboard` 等新增字符串——代码确实在发布包里。

**交互方式已变更**（旧版点击麦克风弹出录音弹窗；新版为微信式内联）：点击聊天输入栏的麦克风按钮后**不再弹窗**，而是输入框原位替换为“按住说话”按钮（麦克风键同时变为键盘键，可切回文本输入）；**按住**该按钮才开始录音并显示毛玻璃覆盖层，上滑取消、松手发送、60 秒自动发送。

已补验证：
- 新增点击路径回归测试（`tapping the mic button switches to the hold-to-talk field`）：点击麦克风 → `onVoice` 回调触发、“按住说话”出现、输入框消失——**链路本身是通的**（测试修复过程中发现并纠正了测试自身两个静态字段不一致的笔误）。
- 真机“无反馈”的最可能根因是**麦克风权限**：首次按住时系统请求权限，若拒绝则录音启动失败、覆盖层一闪即逝，仅有一条易被忽略的顶部 toast。已加固为**对话框强提示**（“无法访问麦克风——请在系统设置中允许畅聊使用麦克风，然后重新按住说话”）。
- 请在**升级到 0.3.10 后**按新交互验证：点麦克风 → 输入栏变“按住说话” → 按住。若弹“无法访问麦克风”对话框，请到系统设置开启麦克风权限。

## 2. 发送消息即时反馈（按澄清调整）

- 发送中的消息**视觉上等同已发出**：移除气泡旁的转圈与半透明处理（`WeChatMessageBubble` 的 sending 分支删除；`_messageRow` 的 deliveryState 映射 sending→sent 视觉）。
- 失败仍显示红色感叹号，点击原位重发、不产生副本（`RoomTimelineController.retry` + `onRetry` 接线，测试覆盖“失败→重发→无副本”）。

## 3. “设置 → 关于畅聊”版本号

根因：`AppConfig.appVersionName/appBuildNumber` 为**硬编码常量**（停留在 0.3.5+8，`tests/mobile/test_app_build_contract.py` 仅在 verify.ps1 全量跑时才校验，此后发版未再触发）。

修复：
- 新增 `package_info_plus: 8.3.0`（精确版本）；`main()` 启动即 `AppConfig.loadRuntimeVersion()` 从安装包清单读取**真实版本/构建号**覆盖默认值；“关于畅聊”“当前版本”“版本更新”页与 presence 心跳上报全部使用运行时值。平台通道不可用时回退到与 pubspec 同步的默认值（0.3.10/13，契约测试继续通过）。
- 测试：`app_config_test` 新增运行时回退用例。

## 回归与发布

- `flutter test` **434 passed**（新增 3 项）；`flutter analyze` 零问题；`pytest tests/mobile/test_app_build_contract.py` 2 passed。
- 发布：0.3.10+13 三架构签名 APK 上传（arm64 SHA256 `7AD711315FABD8CE6A7CD3BFA1625992A71F4DEEC0DD4A9615C4ED02FBDB51E3` 服务端比对一致）；更新设置（幂等键 `app-update-publish-0.3.10-20260830`）确认下发；外部验证 PASS。
