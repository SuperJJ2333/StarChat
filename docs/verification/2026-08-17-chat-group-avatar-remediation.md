# 2026-08-17 群聊、聊天能力与头像修改验证证据

## 修复范围

- 消息页“更多”和通讯录“群聊”入口连接到真实 Matrix 私有加密群聊创建流程。
- 群聊允许“当前用户 + 1 位好友”创建非直聊房间；邀请对象去重，并等待新房间进入同步状态。
- 聊天输入区补齐附件、语音、表情、发送入口。
- 附件面板补齐照片、文件、彩币红包；图片和文件沿用 Matrix 加密媒体上传。
- 彩币红包由 Business API 创建，Matrix 只发送红包 ID 与祝福语引用；分享重试不会重复创建红包或重复扣款。
- 消息时间线补齐 40px 头像、头像点击好友详情、消息时间及 5 分钟会话分割线。
- 支持文本、图片、文件、语音、红包引用消息类型；加密图片按需下载、解密及失败重试。
- Profile 头像进入独立页面，支持相册选择、裁剪压缩、预览、上传、失败重试、权限提示和恢复默认头像确认。
- 修复短语音与麦克风启动失败时录音器未回到 idle/未清理的问题。

## TDD 证据

- 群聊 Controller 初次测试因缺少实现编译失败；实现后聚焦测试通过。
- 聊天表情入口测试初次因 `onEmoji` 缺失编译失败；实现后通过。
- 时间分割与红包引用测试初次因模型/接口缺失编译失败；实现后通过。
- 消息头像组件测试初次因 avatar slot 缺失编译失败；实现后通过。
- 红包 Controller/Sheet 测试初次因类型缺失编译失败；实现后通过。
- Profile 头像流程测试初次因 `ProfileAvatarPage` 缺失编译失败；实现后通过。
- 短语音清理测试初次观察到 cancel 次数为 0；修复后通过。
- 麦克风启动失败测试初次抛出异常并停留 recording；修复后通过。
- 单好友群聊测试初次因“至少两位好友”约束失败；修复后 4/4 聚焦测试通过。
- 加密图片挂载测试初次因组件缺失失败；修复 State 初始化顺序后 6/6 聚焦测试通过。

## 自动验证

- `flutter analyze`：PASS，0 issues。
- `flutter test`：PASS，116 tests（最终完整回归）。
- `python -m pytest tests/mobile/test_figma_ui_contract.py -q`：PASS，10 tests。
- `pwsh.exe -NoProfile -File scripts/verify.ps1`：PASS：
  - Matrix Bot：9 passed
  - Business API/Worker：161 passed, 1 skipped
  - Flutter boundary：19 passed
  - Repository/Deployment/OpenAPI/Migrations/Compose：PASS
- `flutter build apk --debug --target-platform android-x64`：PASS。

## 雷电模拟器实机证据

- 设备：`emulator-5554`，安装包：`com.liuhetong.mobile`，`adb install -r` 返回 `Success`。
- 登录态保留并正常启动，进程存在，未发现本应用 FATAL EXCEPTION。
- “更多”语义树存在并可点击：发起群聊、添加朋友、扫一扫、外观。
- 测试账号仅 1 位好友时，选择好友后“创建群聊（1）”为 enabled；点击后成功进入名为 `friend-two` 的新 Matrix 群聊，页面显示“暂无消息”和完整输入工具栏。
- 好友聊天语义树包含真实历史消息、时间 `09:51`、可点击头像、添加附件、语音消息、表情与发送。
- 附件面板包含照片、文件、红包；群红包页面包含拼手气/普通红包、金额、份数、祝福语和发送按钮。
- Profile 头像独立页面包含当前头像、从相册选择、恢复默认头像。

## 证据文件

- `docs/verification/screenshots/2026-08-17-chat-features-installed-2.png`
- `docs/verification/screenshots/2026-08-17-chat-more-window.xml`
- `docs/verification/screenshots/2026-08-17-group-chat-window.xml`
- `docs/verification/screenshots/2026-08-17-group-chat-final-window.xml`
- `docs/verification/screenshots/2026-08-17-group-created-window.xml`
- `docs/verification/screenshots/2026-08-17-chat-window.xml`
- `docs/verification/screenshots/2026-08-17-attachment-window.xml`
- `docs/verification/screenshots/2026-08-17-red-packet-window.xml`
- `docs/verification/screenshots/2026-08-17-profile-avatar-window.xml`

## 边界审查

- Matrix 仍是端到端加密通信域；没有把消息明文、附件明文或房间密钥交给 Business API。
- 红包资产状态只来自 Business API；Matrix 事件不包含金额、余额、领取状态或账本状态。
- 红包创建与 Matrix 分享分阶段处理，分享失败只重试引用，避免重复金融写入。
- 头像上传继续使用既有 `ProfileGateway` 上传会话，不改变服务端授权边界。
