# 语音通话与视频通话（微信式）— 实现与验证（2026-08-31 / 0.3.19+22）

基于既有 Matrix VoIP + flutter_webrtc 加密通话底座（`matrix_call_adapter.dart`：
m.call.* 信令 + DTLS-SRTP 端到端加密媒体，仅限已验证的加密双人会话），本轮补齐
微信式通话体验与系统级能力。

## 需求实现

### 1. 来电/呼叫接收（前台/后台/锁屏/进程存活）

- **检测**：Matrix 客户端常驻同步（进程存活即在线），`m.call.invite` 信令
  经 `MatrixCallBackend._validateIncoming` 校验（加密双人房间、双方在房）
  后进入来电态；非法房间自动拒接。
- **来电提醒**：新增 `CallAlerts` 响铃循环（即时触发 + 1.8s 间隔循环），
  系统提示音 + 强震动成对出现；接通/挂断/拒接/超时立即停止；驱动异常
  不影响通话状态机。
- **覆盖与其他应用之上**：新增 `CallNotifications.showIncoming` —— Android
  **全屏意图（full-screen intent）** 通知（`USE_FULL_SCREEN_INTENT`，category
  call，max importance），后台/锁屏/其他应用界面之上弹出来电，点击拉起
  接听页（应用内 `incomingCallActive` 覆盖层自动呈现，通话页已挂
  `showWhenLocked`/`turnScreenOn`）。
- 前台时直接由应用内全屏接听页呈现（拒绝/接听双圆钮）。

### 2. 通话流程

- 完整状态机 `CallPhase`：请求权限 → 呼叫/等待 → 接通 → 结束/失败/权限拒绝；
  来信事件驱动（connected/ended/networkInterrupted）。
- **超时自动取消**：主叫等待 `callRingTimeout`（60 秒）无应答自动挂断，
  提示「对方无应答，已取消」；接通后定时器失效（不会误挂）。
- 对方拒接/挂断经信令 ended 事件呈现「通话已结束」；ICE 失败映射为
  「网络中断，通话已结束」；通话中可随时挂断退出（挂断失败兜底按结束处理，
  界面不卡死）。

### 3. 权限与媒体

- 麦克风/摄像头经 `WebRtcPermissionGateway`（getUserMedia 探测）申请；
  拒绝时区分展示「权限被拒绝」并不发起信令；来电拒接并提示。
- 语音通话采集/播放经 WebRTC + `MODIFY_AUDIO_SETTINGS`（听筒/免提路由
  `Helper.setSpeakerphoneOn`）；视频通话实时传输，`switchCamera` 支持
  前后摄像头切换；接通即有回声消除/自动增益（WebRTC 内置）。
- **视频接通默认开免提**（微信语义），语音保持听筒。

### 4. 后台与持久化

- **通话中前台服务**（`CallNotifications.showOngoing`，类型
  `microphone|camera`，Manifest 已声明对应权限与服务类型）：按 Home 键或
  切换应用后进程保持前台服务态，通话继续；结束即 `stopForegroundService`。
- 通话页打开期间屏幕常亮（`wakelock_plus`，退出/平台不支持时安全恢复）。
- 锁屏来电：全屏意图 + `showWhenLocked`/`turnScreenOn`。

### 5. UI（微信式）

- **来电**：深色全屏、对方头像+昵称+「邀请你进行语音/视频通话」、底部
  白圆红图标「拒绝」/ 绿圆白图标「接听」。
- **语音接通**：头像+昵称+实时时长（mm:ss，超时 h:mm:ss），底部
  静音 / 挂断（红）/ 免提。
- **视频接通**：远端画面全屏铺底、本端画中画右上（前置镜像）、左上昵称+
  时长；底部 切换镜头 / 静音 / 挂断（红）/ 免提；等待态文案
  「正在等待对方接听…」。

### 6. 技术质量

- 媒体经 DTLS-SRTP 端到端加密（密钥仅在双方设备）；TURN（coturn 容器）
  保障 NAT 穿越网络连通；ICE 失败有明确的「网络中断」终态提示。
- 后台传输/麦克风可见性依赖前台服务类型（Android 14+ 语义）。
- 真机稳定性/耗电需真机环境复核（本工作区无真机）；已在雷电模拟器完成
  安装与启动回归。

## 测试与验证证据

| 项 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found |
| 全量 `flutter test` | **465 passed**（新增：主叫 60s 超时自动取消且信令挂断、接通后超时失效、响铃循环启停与异常容错、视频接通默认免提、connectedAt/时长格式化、通话页三态 UI） |
| 视觉验收（judge） | 来电/语音接通/主叫等待三张全过（`artifacts/2026-08-31/calls/`） |
| 模拟器 | `adb install -r -d` Success；`versionName=0.3.19`；启动正常（pid 存活，无 FATAL） |

## Manifest 变更

新增权限：`VIBRATE`、`WAKE_LOCK`、`USE_FULL_SCREEN_INTENT`、
`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_MICROPHONE`、
`FOREGROUND_SERVICE_CAMERA`；`MainActivity` 增加 `showWhenLocked`/
`turnScreenOn`；注册本地通知插件前台服务（`microphone|camera` 类型）。

新依赖：`wakelock_plus`（pub add 解析 1.3.3，显式写入 pubspec）、
`video_compress`（上一轮）。

## 已知边界

- 真机验证（微信级音视频质量、耗电、真机锁屏来电）需在真机环境复核；
  模拟器无第二账号，端到端双端通话需两台设备联测。
- iOS CallKit/推送唤醒未在本轮范围（Android 全链路已覆盖）。
- 版本保持 0.3.19+22（未发布）：下次发布时推送 `latest_build=22` 即可
  让 0.3.18 用户收到更新弹窗（客户端归一化修复已具备弹窗条件）。

## 更新推送发布（2026-08-31 追加）

- 三架构 0.3.19 APK（arm64 `2c3f901c…`、arm32 `89307cc4…`、x86_64 `662afb6b…`）
  已上传 `/opt/starchat/frontend/downloads/`，服务器端 sha256 与本地逐一比对
  一致；`latest-arm{32,64}.apk` / `latest-x86_64.apk` 别名同步刷新。
  大文件直传会被服务器重置连接，改用 4MB 分块上传 + 服务器端重组 +
  哈希比对完成。
- 管理端发布（幂等键 `app-update-publish-0.3.19-20260831`）：
  `latest_version=0.3.19`、`latest_build=22`、`min_supported_build=3`、
  `apk_url=https://www.liuhetong888.com/downloads/ChatFlow-0.3.19-arm64.apk`；
  容器内 `GET /api/v1/app-updates/latest` 回读 PASS，脚本
  `artifacts/2026-08-31/publish_app_update_0.3.19.py`。
- 外部抽测：APK URL 206 + `50 4B 03 04`（ZIP/APK 魔数）。
- 生效语义：0.3.18（build 21）及更早的 0.3.18+ 客户端启动时将弹出
  「发现新版本 0.3.19」更新弹窗；0.3.19 客户端（归一化后 22=22）不再弹窗。
  0.3.17 及更早客户端因旧版比较缺陷仍需经落地页下载。

## 0.3.16 收不到更新弹窗的修复（2026-08-31 追加）

**根因**：0.3.16/0.3.17 客户端的更新比较使用 Android 原始 versionCode，
它带分 ABI 偏移（`abiIndex*1000 + build`：arm32=1xxx、arm64=2xxx、
x86_64=4xxx），而 `latest_build` 此前为普通构建号（22）——任何旧客户端的
比较结果都是 `4xxx/2xxx/1xxx ≥ 22`，因此永远显示"当前已是最新版本"。
该缺陷已在 0.3.18 归一化修复，但旧客户端自身无法回溯。

**修复（双层）**：

1. **0.3.20+23 客户端**：`resolvePendingUpdate` 优先做**语义化版本比较**
   （`latest_version` vs 当前版本名，`compareVersions` 点分整数逐段比较），
   构建号比较仅作版本名不可解析时的回退——更新判断从此与打包方案解耦
   （`tests/features/update/app_update_test.dart` 新增语义比较/回退/同版本
   抑制用例；全量 468 passed）。
2. **服务端发布策略**：`latest_build` 改用 **arm64 清单值**（`2000+build`，
   本轮发布 2023）。旧客户端（arm64=2019、arm32=1019）比较成立，可正常
   弹窗/检查更新；新客户端由语义比较保证同版本不误报。

**发布记录**（幂等键 `app-update-publish-0.3.20-notes2-20260831`）：
`latest_version=0.3.20`、`latest_build=2023`、
`apk_url=…/ChatFlow-0.3.20-arm64.apk`；三架构 APK 分块上传，服务器端
sha256 与本地一致（arm64 `315bd5bf…`、arm32 `79c76c09…`、x86_64 `caf56b57…`），
`latest-*.apk` 别名刷新；外网抽测 206 + ZIP 魔数。

**生效预期**：
- 0.3.16/0.3.17 **真机**（arm64/arm32）：启动弹窗 + 关于页"版本更新"均提示
  发现新版本 0.3.20 ✓；
- 0.3.16/0.3.17 **x86_64 模拟器**（4xxx）：受旧客户端缺陷限制仍无法提示
  （4xxx 恒大于任何可行发布值），需经落地页手动安装一次；
- 0.3.18/0.3.19 客户端：正确提示更新到 0.3.20（它们确实过期）；
- 0.3.20 客户端：语义比较判定同版本，安静不再误报；后续 0.3.21+ 发布
  对所有 ≥0.3.18 客户端正常弹窗。

## 0.3.20 八项 UI/交互 BUG 修复（2026-08-31 追加，二次构建）

构建说明：本节修复完成后**重新构建并替换**了服务器上的 0.3.20 三架构包
（发布约一小时、无外部下载者，同版本覆盖安全），`latest-*.apk` 别名同步刷新；
新哈希：arm64 `084f9ff4…`、arm32 `2a845c3f…`、x86_64 `7a43c187…`。

1. **图片页视频格式**：缩略图解码失败不再丢弃条目（占位底色仍可选可发）；
   MIME 按系统媒体库真实值透传（MP4/MOV/MKV/AVI…），原样发送不再一律 mp4。
2. **选择页交互**：点击缩略图=全屏放大预览（新 `_GalleryPreviewPage`，
   1280px 按需解码 + 缩放），右下角"选择/已选择"胶囊与网格左上角圆圈
   等效切换选中；两个点击区域严格分离。
3. **图片消息头像/昵称**：图片消息改经 `WeChatMessageBubble
   (decorateContent:false)` 渲染，补齐此前缺失的头像与发送者昵称。
4. **会话摘要标签**：新增 `conversationEventSummaryLabel`——
   m.image→[图片]、m.video→[视频]、m.audio→[语音]、m.file→[文件]、
   通话摘要→[语音通话]/[视频通话]；不再出现"畅聊附件"占位。
   同时落地**通话摘要消息**：呼叫方在通话结束时发送 `com.changliao.call`
   自定义消息（接通=时长，未接通=已取消），双端时间线渲染电话 icon 行。
5. **会话名称备注优先**：`_memberIdentity` 传入备注，
   `conversationSenderName` 链路补 username 回退（备注→昵称→用户名→
   Matrix 展示名→localpart）；原"隐私红线"注释按新需求更新（备注仅为
   查看者本地数据，无泄露面）。
6. **群成员备注优先**：群聊信息页成员网格/单元格/成员搜索/移除页/关注
   成员页全部经 `_resolvedMemberName`（identityCache 备注→昵称→用户名）。
7. **备注修改即时刷新**：identityCache 为 ChangeNotifier，`applyUpdatedContact`
   （联系人资料页已有）触发监听——会话列表（matrix_home）、聊天页
   （room_page）、群聊信息页（本轮新增监听+实时解析）即刻刷新。
8. **群聊导航标题**：`groupRoomNavigationTitle` 改为"群名（N）"、默认
   "群聊（N）"（全角括号）；`WeChatNavTitle` 增加 maxLines=1+省略号。

测试：全量 `flutter test` **469 passed**、`flutter analyze` 0 issue
（新增：媒体/通话摘要标签映射、群导航标题新规则、选择页预览/圆圈分离、
预览页选择联动、发送方语义变更的适配）。
模拟器：0.3.20 修复包（x86_64，sha256 前 16 位 `7a43c187…`）安装成功、
启动正常。

## 0.3.21 表情交互/混排动效/工具面板 发布（2026-08-31 追加）

1. **emoji 面板三栏图标切换**：顶部三栏改为**纯图标**标签——表情（笑脸
   `CupertinoIcons.smiley`）、超级表情（特效 `sparkles`）、我的表情（心形
   `heart_fill`），带 Key 与语义标签；三栏切换完整展示对应类别
   （矢量静态 / 动态 WebP / E2EE 自定义表情），选中态同步。
2. **混排动效**：`EmojiText`/`buildEmojiInlineSpans` 改为**动态库优先**——
   命中 Animated Fluent WebP 的 emoji 以 `EmojiAnimatedGlyph`
   （`Image.asset` 自动逐帧播放）内联渲染，未收录的回退矢量 SVG；
   文字+emoji 混排、消息气泡、历史记录中的 emoji 均持续动画。
   输入框内为系统输入法渲染（原生彩色 emoji），动态效果自发送后生效。
3. **工具面板（可扩展）**：新增 `ChatTool`（id/name/icon/onTap）与
   `ChatToolRegistry`（register/unregister/clear，同 id 覆盖），
   `ChatToolsPanel` 自动渲染注册表（空态“更多工具即将上线”）；
   “更多”面板末位新增“工具”入口（`chat-more-tools`）。
4. **emoji 面板自动收起**：面板展开态点击输入框 → 面板收起并聚焦弹出
   键盘（`WeChatComposer.onInputTap` → room_page
   `_dismissEmojiPanelForInput`，同帧处理避免遮挡跳动）；其它区域
   保持原逻辑。

测试：全量 `flutter test` **475 passed**、`flutter analyze` 0 issue。
发布（幂等键 `app-update-publish-0.3.21-20260831`）：`latest_version=0.3.21`、
`latest_build=2024`（arm64 清单值方案）、
`apk_url=…/ChatFlow-0.3.21-arm64.apk`（外网 206 + ZIP 魔数）；服务器端
三架构 sha256 与本地一致（arm64 `85241dd8…`、arm32 `a95d0519…`、
x86_64 `bfef22f3…`），`latest-*.apk` 别名刷新。生效语义：0.3.20 用户
（语义比较 0.3.20<0.3.21）弹窗；更早客户端同前述规则。
模拟器：x86_64 包安装成功、`versionName=0.3.21`、启动正常。

## 五项缺陷严格修复（2026-08-31 第三批，加固重建发布）

1. **图片页视频格式 + GIF**：缩略图解码失败的条目不再丢弃（占位底色，
   仍可选可发）；MIME 按系统媒体库真实值透传（MP4/MOV/MKV/AVI/3GP…，
   扩展名兜底表 `mimeFromFileName`）；**GIF 走原图字节发送**
   （compressedBytes 对 GIF 返回 originBytes），压缩重编码不再把动画
   打成静态图；聊天端 `Image.memory` 原生逐帧播放。
2. **视频类文件（畅聊附件）发送**：`sendEncryptedMedia` 支持 `filename`
   透传（真实文件名+扩展名，不再一律"畅聊附件"）；`sendFile` 对
   file_selector 返回 null MIME 的机型按扩展名推断；发送加 **5 分钟
   超时**（超时明确提示，不再无限"正在发送"）；发送完成主动刷新时间线
   （图片批量/拍摄/文件三条链路统一），发出事件即时落位。
3. **通话结束多余页面 + 摘要去重**：`CallPage` 增加
   `autoCloseOnEnd`（呼出路由已开启），ended/failed/permissionDenied
   即刻自动 pop，"通话已结束"独立页面彻底移除；通话摘要消息加
   `callSummarySent` 去重护栏（ended 分支可能随 notifyListeners 多次
   进入），一次通话只落一条状态气泡。
4. **语音播放动效（暂停/继续 + 真实进度）**：引擎扩展 `pause/resume/
   position`（audioplayers pause/resume/onPositionChanged）；
   `VoicePlaybackController` 新增 paused 态与 position 流——
   播放中点击=暂停（高亮定格）、暂停中点击=从暂停位置继续、自然结束
   复位；气泡扫过进度改由**真实播放位置**驱动（`playback`+`messageId`
   注入，估算扫过仅作无控制器回退）。引擎接口变更已同步测试桩。
5. **安装报毒（加固重建）**：定位并修复发布脚本
   `--split-debug-info=$mobileRootuild` 的路径损坏（`\b` 退格字符），
   发布链路恢复 `--obfuscate + --split-debug-info`；0.3.21 三架构以
   **加固方式重建并替换**服务器产物（arm64 `e9d9bbf6…`、arm32
   `6c9167c5…`、x86_64 `a480221c…`），`latest-*.apk` 别名刷新，
   外网抽测 206。

测试：全量 `flutter test` **477 passed**、`flutter analyze` 0 issue
（新增：暂停定格/继续/真实位置驱动、文件发送超时与刷新、通话摘要去重
语义适配）。模拟器：加固 x86_64 包安装成功、启动正常。
真机复核项：MKV/AVI 缩略图与发送、GIF 动画播放、5 款安全软件安装扫描。

## 0.3.22 新版本推送（2026-08-31 追加）

- 版本 **0.3.22+25**（加固构建 `--obfuscate --split-debug-info`），含
  0.3.21 全部改进与五项缺陷修复（视频格式/GIF、附件发送、通话结束页、
  语音暂停继续、安全加固）。
- 三架构 APK 分块上传，服务器端 sha256 与本地一致（arm64 `46a7f977…`、
  arm32 `81e6de0d…`、x86_64 `228c31cc…`），`latest-*.apk` 别名刷新，
  外网抽测 206 + ZIP 魔数。
- 更新设置发布（幂等键 `app-update-publish-0.3.22-notes2-20260901`）：
  `latest_version=0.3.22`、`latest_build=2025`、`apk_url=…/ChatFlow-0.3.22-arm64.apk`，
  容器内外回读 PASS。
- **新增发现与处理**：`app_settings` 值列为 varchar(255)，过长的更新说明
  会导致 PUT 500（`StringDataRightTruncation`）且部分字段已落库造成
  版本与说明不一致；已将更新说明压缩至 250 字符内并复发布成功。
  （后续可考虑将该列迁移为 TEXT，expand-only。）
- 生效语义：0.3.21 及更早的 ≥0.3.18 客户端启动/关于页检查均提示
  发现新版本 0.3.22；模拟器已安装 0.3.22（当前最新，不再弹窗，符合预期）。

## a.gray.BulimiaTGen.f 报毒处置（2026-08-31 追加，0.3.23+26）

**判定性质**：`a.gray.BulimiaTGen.f` 是腾讯 TR 引擎的**灰度行为泛型判定**
（gray=灰色行为，非确认病毒），典型命中特征为“应用启动后静默联网下载
文件到本机 + 自更新能力”的行为组合。

**代码侧处置（本轮）**：
- 移除启动时**静默资源热更新通道**（`ResourceUpdateService` /
  `NetworkResourceUpdateGateway` 及 app_home 启动调用、相关测试整体删除）；
  该功能为内部灰度能力，其“启动后静默拉取清单并下载文件写入本机”模式
  是灰度判定的核心命中点。
- 应用内更新保持“仅跳转外部浏览器下载”，无应用内下载安装路径；
  权限清单维持最小化（通话必需项）。

**发布**：0.3.23+26（加固构建），三架构分块上传（arm64 `8daee1ee…`、
arm32 `5b44634d…`、x86_64 `d010dcab…`），`latest-*.apk` 别名刷新，
外网抽测 206；更新设置发布（幂等键
`app-update-publish-0.3.23-20260901`）`latest_version=0.3.23`、
`latest_build=2026`；模拟器安装启动正常。

**残余风险与厂商加白（根本解决路径）**：
泛型启发式无法通过单次代码改动保证转阴，标准处置是**厂商误报申诉加白**：
1. 腾讯TR引擎申诉平台（virs.qq.com）提交 arm64 包
   （sha256 `8daee1ee…`，联系方式+企业说明+加固说明），一般 1–3 工作日；
2. 华为/小米/OPPO/vivo 应用市场“误报申诉”入口同步提交；
3. 申诉通过后，同签名的后续版本命中概率大幅下降。
申诉材料模板已具备（包名 com.liuhetong.mobile、版本 0.3.23、
签名指纹与下载地址见本文件）。
