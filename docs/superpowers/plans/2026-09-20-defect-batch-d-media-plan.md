# 畅聊缺陷清单 0917 · 批次 D（媒体与连播增强 + BUG-23 残余自愈）实施计划

日期：2026-09-20。状态：**待用户批准**（批准后按本文件执行）。
前置：批次 A–C 已全部落地并随 0.3.102/2142 发布（线上 Android `latest-arm64.apk` 与 iOS OTA `manifest.plist` 均为 0.3.102/2144）；批次 B 服务端三文件（identity.py / registration.py / config.py）已于 2026-09-20 恢复部署并固化为镜像 `starchat-business-api:defect-restore-20260920`（见任务记录 `docs/workflow/tasks/2026-09-20-defect-batch-d-prep.md`）。

## 1. 范围与决策点

| 项 | 内容 | 决策依据 |
| --- | --- | --- |
| BUG-28 | 编辑图片连续发送尺寸不一致的根因修复 | 原计划批次 C 未完成项 |
| BUG-35 | 相册视频发送接入百分比进度（转码/上传），失败可重试 | **D5 已拍板：不做暂停** |
| BUG-40 | 同会话语音连播 + 设置开关 | **D7 已拍板：默认开启**（修正早期"默认关"建议） |
| BUG-23 残余 | 通话结束后未读的最后一类滞留场景自愈 | 客户端先行已发布；服务端剔除信令**结构性不可行**（见 §5） |

非目标：不做发送暂停（D5）；不改 Matrix 加密协议与信令格式（AGENTS.md 边界）；不动业务服务端（本批次无服务端改动）；生产 business-api 与 main 的 77 文件结构性漂移治理为独立运维任务，需用户另行授权（见 §7）。

## 2. BUG-28 编辑图片连续发送大小不一致

- 现象：编辑态同一图片连续发送 2 次，气泡/布局尺寸不一致。
- 根因（CSV + 批次 C 复核）：发送路径 `matrix_e2ee_client.dart`（`buildMediaFileForSend` 之后、`OutgoingMediaThumbnailCache` 缩略图分支，约 :6990–7005）在 `thumbnail == null` 时才走 `generateThumbnail`；附了缩略图的信封缺少**顶层 `info.w/h`**，接收端两次发送分别命中"有顶层宽高"与"回退 thumbnail_info 宽高比"两条渲染路径 → 布局不同。
- 修复设计：
  1. 发送侧：构造信封时始终把解码后的原始尺寸写入事件 `info.w/h`（数据来源为已解码 `MatrixImageFile` 尺寸；缩略图有无不影响顶层宽高）。
  2. 展示侧：气泡宽高比解析顺序统一为 `info.w/h → thumbnail_info → 默认占位比`，两条路径收敛到同一函数（新增纯函数 + 单测）。
- TDD：失败用例=同一字节、一次带 thumbnail 一次不带，断言两次事件 `info.w/h` 相等且气泡宽高比解析结果一致；红→绿后补防回归断言。
- 文件所有权：`matrix_e2ee_client.dart`（发送信封）、`wechat_message_bubble.dart` / 图片气泡尺寸解析（如分叉则在公共处收敛）、对应测试。

## 3. BUG-35 相册视频发送进度（D5：不做暂停）

- 现状：`video_send_stage.dart` 已有阶段（转码中 x% / 上传中…）与失败重试；**相册（photo_manager）来源视频未接入**该阶段，只有聊天内直拍有。
- 修复设计：相册视频发送统一走 `prepareLocalChatVideo` → `VideoSendStage` 管道：转码阶段接 `progress`，上传阶段接分片回调；失败保留现有重试语义。不做暂停（D5）。
- TDD：相册视频发送期间 `VideoSendState.phase/progress` 序列断言（转码 0→1、上传阶段存在、失败→可重试）；与既有 `video_send_stage` 测试合并。
- 文件所有权：`room_page.dart` 相册视频入口、`prepared_chat_video.dart` / `video_send_stage.dart`、对应测试。

## 4. BUG-40 语音连播（D7：同会话 + 默认开 + 开关）

- 现状：`voice_playback_controller.dart` 播完即停（完成回调无队列）；`wechat_voice_bubble_test.dart:78` 固化"播完即全亮"（该断言与连播不冲突，保留）。
- 修复设计：
  1. `VoicePlaybackController` 增加同会话连播队列：当前语音**自然播完**后，取同会话下一条（按时间顺序）**未读**语音自动播放；用户手动暂停/切换会话/退出页面即终止队列。
  2. 设置项：`消息与通知` 下新增"语音自动连播"开关，默认开；持久化于既有偏好层（与"减少动态效果"同模式）。
  3. 已读推进：连播推进的每条语音按既有"播放即已读"语义处理，不引入新状态。
- TDD：队列顺序用例（含未读过滤）、中断用例（手动暂停/切页）、开关关闭时行为与现状逐字一致；更新任何固化旧行为的完成回调断言。
- 文件所有权：`voice_playback_controller.dart`、语音气泡完成接线、设置页新增 tile、偏好层、对应测试。

## 5. BUG-23 通话后未读：决策记录 + 客户端残余自愈

- **决策（记录在案）：服务端从通知/未读计数中剔除 m.call.* 在 E2EE 房间内结构性不可行。** 依据：本应用通话信令（`matrix_call_adapter.dart` `_startVerified`，要求 `room.encrypted`）经 Matrix SDK 发入加密房间时间线；事件持久化后服务器只见 `m.room.encrypted`，默认推送规则 `.m.rule.encrypted*`（DM 内逐事件 notify）使 invite/answer/hangup/candidates 全部计入 `unread_notifications`。服务器在不接触明文的前提下无法区分信令与消息（AGENTS.md 明令禁止向服务器提供明文）；生产 Synapse 分叉仅含媒体去重与登录兼容补丁，无推送规则定制。治本路径（信令迁移 to-device / 不入时间线）属信令协议改造，不在本批次。
- 已发布（0.3.102/2144）：通话终态首现即 `markRoomRead`（`matrix_e2ee_client.dart:1110`，覆盖主叫/来电/最小化路径）。
- 残余场景：通话进行中客户端进程被杀/设备离线 → 终态 `onEnded` 未执行 → 重启后房间未读含信令事件，直到下次交互。
- 自愈设计：同步恢复/会话列表投影时，若某房间**最新已解密事件为通话信令**（复用 BUG-14 的 `callVideo` 判定链）且 `serverUnreadCount > 0` 且无活跃通话租约 → 推进一次 read marker 至该事件（幂等、静默、无 UI 噪音）。语义与已发布的"通话结束推进已读"一致，只是把触发点补到进程重启后。
- TDD：失败用例=构造最新事件为 m.call.hangup 的房间 + unread=2 + 无活跃通话 → 断言 setReadMarker 被调用一次；反例=最新事件为普通消息时不触发；活跃通话存在时不触发。
- 文件所有权：`matrix_e2ee_client.dart`（自愈判定与调用点）、`conversation_read_state.dart`（如需暴露只读判定）、对应测试。

## 6. 门禁与交付

1. 每项先失败用例后实现；定向套件绿。
2. `flutter analyze lib test` 0 issue；全量 `flutter test --timeout 120s` 通过。
3. `pwsh -NoProfile -File scripts/verify.ps1`（如环境就绪）或按环境记录阻断项。
4. 无服务端改动 → 无迁移/契约变更；OpenAPI 不动。
5. 完成后随下一版本发布（用户指示版本号与渠道）；CSV 四行状态回填。

## 7. 独立运维事项（不在本批次，需用户授权）

生产 `business-api` 运行树与 main 存在 **77 个文件的结构性漂移**（镜像 fb41d7fa 构建自陈旧/脏源码树，2026-09-20 已用三文件覆盖恢复缺陷批次行为并固化镜像 `defect-restore-20260920`）。建议单独立项：从干净 main 源码树重建 business-api 镜像并按 admin 流程切换，消除"每次容器重建都可能丢失覆盖层"的系统性风险。切换前需完整后端回归与真实 PG 演练。
## 8. 执行追加（2026-09-20/21，用户指令后实施）

用户在批准本计划时新增两个缺陷（并入批次 D）与一项服务器授权：

- **服务端干净镜像重建（已授权并完成）**：生产 business-api 已切换为
  `starchat-business-api:main-clean-20260920`（215/215 文件与 main 一致；迁移头
  0071==0071 无变更；回退镜像 caibi-grant-20260920）。落地前先把并行会话当日
  部署的 caibi 储备策略增量（admin.py+ledger.py）按生产运行字节落回 main
  （commit 89606cad），保证"干净 main"包含全部生产行为。
- **E1（新缺陷）低端安卓（MagicOS 8.0/荣耀50 Plus/Android14）群聊打字卡死**：
  根因=`_recordGlobalSearchIndex()` 在每次时间线变化时把房间全部消息重建进
  搜索索引（O(N log N) 分配+排序，UI 线程），群聊每条新消息触发一遍。修复=
  增量投影（`RoomSearchIndexScheduler`，echo 不入库、撤回联动删除）+ 400ms
  去抖；`GlobalSearchIndex.removeMessages` 新增撤回删除能力。
- **E2（新缺陷）红包/转账气泡状态闪烁**：根因=`FinanceCardStore` 挂在
  RoomPage State 上，每次进入房间重建 store → 缓存清零、所有卡片重新拉取
  闪 loading。修复=`sessionFinanceCardStore()` 进程级共享、会话失效
  （登出/换号/401）才重建（微信式机制）。
