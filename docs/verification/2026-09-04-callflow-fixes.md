# ChatFlow 五联修验证记录（2026-09-04）

范围：个推后台推送链路 / 被叫接听后页面消失 / 视频封面 / MIUI 相册视频 /
视频重复加载 + TURN 诊断扩展。全部测试先行（先红后绿），本地 commit，
不发布 APK（真机清单见 §14）。

## 1. 根因结论（探索实证）

| # | 问题 | 根因 |
| --- | --- | --- |
| A | 个推后台无提醒 | 7 项叠加：CID 竞态无重试、EventChannel 回放 bug（代码在 lambda 内永不执行）、老用户无隐私同意记录、无 resume 重检、bridge 临时错误进 rejected（Synapse 删 pusher）、限频吞来电、type 缺失误判 |
| B | 被叫接听后页面消失 | `connected` 时 `incomingCallActive=false`，而 CallPage 仅在该标志为 true 时挂载——接通即卸载 |
| C | 视频无封面 | SDK `sendFileEvent` 以 `...extraContent` 浅合并收尾，`{'info':{'duration':…}}` 整体覆盖 SDK 已建的 info（thumbnail_file 丢失）；且单点 200ms 抽帧常命中片头黑帧 |
| D | MIUI 相册无视频 | `pagerFor(album)` 不传 RequestType——"本地视频"（entity=null）退化为 common 混合查询 |
| E | 视频重复加载 | `VideoViewerPage` 每次 `loadAttachment` 全量下载解密 + 写系统临时文件且从不清理 |

## 2. 变更文件

**客户端（apps/mobile_flutter）**

| 文件 | 变更 |
| --- | --- |
| `android/.../MainActivity.kt` | EventChannel onListen 立即回放当前 CID（A1） |
| `lib/features/push/getui_push_token_provider.dart` | initialize 可重试、token() 轮询 ≤8s、hasCid() 探针（A2） |
| `lib/features/push/matrix_pusher_service.dart` | 指数退避状态机（10s/30s/2m/10m）、recheck、登出取消重试（A3） |
| `lib/features/push/push_status_registry.dart` | 新增：诊断页通道状态登记（脱敏） |
| `lib/app_home.dart` | 老用户同意迁移、resume 重检、状态机接入来电覆盖层（A4/B）、登出清理 |
| `lib/features/settings/notification/notification_diagnostics_page.dart` | 顶部推送状态摘要（隐私/SDK/CID 存在性/网关/注册/权限） |
| `lib/features/matrix/incoming_call_overlay_state.dart` | 新增：ringing（通知语义）与 pageVisible（挂载语义）分离（B） |
| `lib/features/matrix/matrix_media_file.dart` | 新增：extraContent.info 内联进 MatrixVideoFile/AudioFile（C1） |
| `lib/features/matrix/matrix_e2ee_client.dart` | sendEncryptedMedia 走 buildMediaFileForSend（C1） |
| `lib/features/matrix/video_poster_extractor.dart` | 新增：200/500/1000/2000ms 多时间点抽帧 + BT.601 亮度近黑帧检测（C2） |
| `lib/features/matrix/device_gallery_source.dart` | 封面走多时间点抽取（回退 photo_manager）；requestTypeForAlbum 透传（C2/D） |
| `lib/features/matrix/video_transcode.dart` | 移除旧单点 extractVideoPoster |
| `lib/features/matrix/media_cache.dart` | 新增 resolveCachedVideoFile（磁盘缓存直读+在途去重）；缓存路径段文件系统安全化（E） |
| `lib/ui/chat/wechat_video_message.dart` | VideoViewerPage 直接播放缓存文件（不再写临时文件）（E） |
| `lib/features/matrix/room_page.dart` | _openVideoViewer 接缓存（E） |
| `lib/features/matrix/call_quality_monitor.dart` | codec/availableOutgoingBitrate/concealmentEvents/iceState（F） |

**服务端（services/getui-bridge）**：`getui_client.py`（GetuiTransientError +
PERMANENT_CODES{10009,20101-20105} + is_permanent）、`rate_limit.py`
（kind 分窗 message 1.5s / call 500ms）、`main.py`（rejected 语义：
永久→rejected，临时→200 空回 Synapse 重试）。

**部署（服务器 207.56.8.8 /opt/starchat）**：bridge 源码同步（md5 比对
9bbbabaf/e10a07eb/1d71a37d）→ 镜像 `starchat-getui-bridge:0.3.35` →
`up -d --force-recreate`。备份：`backups/getui-bridge-20260904-145617`
（3 源文件 + .env）。`docker-compose.yml` 默认 tag 同步 0.3.35。

## 3. 测试证据（红→绿）

| 套件 | 结果 |
| --- | --- |
| `tests/getui_bridge/`（11 既有 + 11 新 error_semantics：永久/临时 rejected、限频分类、type 缺失、多 CID） | **22 passed** |
| `test/features/push/`（含新增 push_status_registry 5：CID 脱敏红线、失败类别、非个推无 SDK/CID 行） | **22 passed** |
| `test/features/matrix/incoming_call_overlay_state_test.dart`（5：接通保持挂载/终态卸载/主叫不覆盖/idle/reset） | **5 passed** |
| `matrix_media_file_test.dart`（6：duration/w/h 内联、非 info 键保留、非法 info 不回传） | **6 passed** |
| `video_poster_extractor_test.dart`（5：黑帧跳过、全黑 null、失败续试、命中即停、亮度标定） | **5 passed** |
| `device_gallery_source_test.dart`（+2：requestTypeForAlbum 映射 + 源码防回归） | **9 passed** |
| `video_viewer_cache_test.dart`（5：首载落盘、重启零解密、并发去重、键控隔离、无临时文件） | **5 passed** |
| `call_quality_and_gate_test.dart`（+3：codec/带宽/隐藏事件解析与 summary） | **12 passed** |
| **flutter test 全量** | **761 passed / 0 failed** |
| **flutter analyze** | **No issues found** |
| **Android debug APK**（含 Kotlin 改动） | **Built app-debug.apk** |
| **scripts/verify.ps1**（业务 API+worker+bot+infra+bridge pytest、alembic、OpenAPI、compose render） | **Verification: PASS** |

红线断言：出站个推载荷逐键白名单（title/body/click_type/notify_id/ttl/
audience.cid）；pusher data 仅 format/url；UI/日志不出现 CID 原值、
MasterSecret、聊天正文（push_status_registry_test 显式断言 SECRET 不渲染）。

## 4. 服务器核验（A6，SSH 实测）

- bridge 容器 env 四变量（APP_ID/APP_KEY/SIGN_SECRET/MATRIX_APP_ID）与
  .env 一致（值掩码比对）；镜像 0.3.35 Up。
- nginx（starchat-gateway 容器）`/_matrix/push/v1/getui/` →
  `getui_bridge_upstream`（resolve）；内网 healthz=200；
  **公网** `POST .../getui/notify` 空载 400（bridge 自身响应，路由通）。
- Synapse：`push.include_content: false` ✅；`render_config --check
  --require-production`（服务器）：**NO DRIFT**。
- TURN：coturn Up，3478/5349 主机监听；**公网 3478/tcp 可达**；
  **5349/tcp 不可达（托管商安全组，人工项）**。

## 5. 安全发现（需用户决策，未擅动）

**🔴 生产 Synapse 使用默认密钥**：`macaroon_secret_key` 与 `form_secret`
均为安装占位值 `change-this-…`（服务器 .env 里就是占位串；render 守卫
未覆盖该键）。风险：知道公网域名的攻击者可伪造 access token/注册
guest。修复：生成随机值→写入 .env→`render_config`→`up -d --force-recreate
synapse`；**代价：所有用户 access token 失效需重新登录**（E2EE 密钥与
已验证设备不受影响）。因影响全体在线用户，留给用户决定执行窗口
（建议低峰期）。

## 6. E2EE 边界复核

- 个推出站仍只含通用文案（无正文/联系人/群名/附件/密钥）；
- pusher 载荷 event_id_only；include_content=false（服务器实测）；
- `usesCleartextTraffic=false` 未动；厂商通道权限剥离未动；
- AppKey/MasterSecret 仅服务器 .env（本仓库全量扫描测试仍绿）；
- 未新增任何客户端→业务 API 的明文媒体路径。

## 7. 兼容性说明

- 视频封面修复对旧消息（无 thumbnail_file）无影响（本就不显示封面）；
  新消息起接收端零下载渲染封面。
- `media_cache` 缓存文件名安全化后，旧缓存文件（原始 Matrix ID 命名）
  不再命中——一次性重新下载，无正确性影响。
- bridge 0.3.35 与旧客户端完全兼容（仅错误语义变宽：临时错误不再删
  pusher）。

## 8. 剩余凭据缺口（不伪造，见 PUSH_SETUP §0.2）

厂商离线通道六家（小米/华为/荣耀/OPPO/vivo/魅族）凭据全部未配置；
FCM/APNs（Sygnal 通道）维持休眠态。App 被杀后的送达当前依赖个推
自通道。

## 9. 服务器人工项

1. 托管商安全组放行 **5349/tcp+udp**（turns 兜底；§5 密钥修复同窗口
   处理更佳）。
2. macaroon/form secret 轮换（§5）。

## 10. 发布说明

客户端改动已全部本地 commit（不 push、不自动发 APK）。发布时走
`scripts/release.ps1`（0.3.35 版本号已在 release 流程内自增），并按
RUNBOOK_RELEASE 配置 GetuiUrl 构建参数。

## 11. 版本

- 客户端：0.3.34+本次修复（发布时 0.3.35）
- getui-bridge：**0.3.35（已部署生产）**

## 12. 回滚

- bridge：`cd /opt/starchat && cp backups/getui-bridge-20260904-145617/*
  services/getui-bridge/app/ && sed -i 's|:0.3.35|:0.3.34|' .env &&
  docker compose build getui-bridge && docker compose up -d --force-recreate
  getui-bridge`。
- 客户端：git revert 对应 commit（无数据迁移）。

## 13. 用户真机测试清单（发布 0.3.35 后执行）

**推送（两台手机，其中一台尽量为华为/小米）**
1. 两台登录不同账号；A 给 B 发消息 → B **息屏**应收到"您有一条新消息"
   （通用文案，无正文）。
2. B 杀掉 App（最近任务划掉）→ A 再发 → B 仍应收到（个推自通道）。
3. A 给 B 拨打语音/视频 → B 息屏应弹**全屏来电**（系统响铃）。
4. B 点击通知 → 直接进入会话/来电页。
5. B 登出再登录 A 账号 → A 账号收推送、B 账号不再收（pusher 已删）。
6. 设置→新消息通知→通知诊断：推送状态摘要应显示
   隐私同意=已同意、SDK=已初始化、CID=已获取、注册状态=已注册、
   网关=liuhetong888.com；**任何地方不得出现 CID 长串原值**。
7. 飞行模式 10 秒恢复 → 诊断页 resume 后仍"已注册"（若曾失败，
   观察自动重试日志）。

**通话**
8. B 接听来电后**通话页面保持显示**（不再消失），可正常挂断/静音/开扬声器。
9. 双方异网通话（如移动 5G ↔ 电信 WiFi）挂断后抓
   `adb logcat -s flutter | grep -a callquality`：记录 turn=、codec=、
   availOut=、conceal=、rtt/jitter/丢包（远距离卡顿请附此行反馈）。

**视频/相册（重点 MIUI 一台）**
10. 相册选择器→"本地视频"分类：应**只列出视频**（MIUI 修复）。
11. 发一段前 1 秒黑场的视频 → 接收端消息卡片应显示**非黑封面**。
12. 同一视频点开大屏、退出、再点开：第二次应**秒开**（磁盘缓存，
    无重复下载）。
13. 播放大文件视频期间退回会话 → 存储占用不应线性增长（无临时文件泄漏）。

**回归**
14. 语音消息、图片原图/压缩发送、朋友圈发布不受影响；E2EE 房间内
    上述全部操作内容仅会话内可见（服务器始终密文）。

## 14. 结论

五个问题全部定位到确定性根因并修复；全部自动化门禁绿（761 单测/
analyze 0/verify.ps1/APK 构建/bridge 22 测试）；服务端 bridge 0.3.35
已部署并公网验证；剩余项均为人工凭据/安全组/密钥轮换决策，已在
§8/§9/§5 列明。
