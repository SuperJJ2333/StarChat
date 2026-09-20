# 任务记录：缺陷批次 D 准备 + 生产服务端修复恢复（2026-09-20）

## 恢复入口

- 目标、用户授权来源及边界：用户指令"完成上一批待办（BUG-23 服务端、BUG-28/35/40、BUG-19 相关遗留），核对缺陷清单 CSV 未修复项，准备下一批修复"。上一批已授权的跨会话生产部署工作流（admin-production-workflow）延续适用于本任务的服务端核验与恢复。
- 关联计划：`docs/superpowers/plans/2026-09-20-defect-batch-d-media-plan.md`（本任务产出，**待用户批准后实施**）。
- 关联：`docs/畅聊缺陷清单-0917-标准化.csv`（本任务已回填 10 行）、上一批记录 `docs/workflow/tasks/2026-09-19-defect-batch-a.md`。

## 结论一：BUG-23 服务端剔除 m.call.* 结构性不可行（决策）

- 客户端通话信令经加密房间时间线发送（`matrix_call_adapter.dart` `_startVerified` 强制 `room.encrypted`）；服务器只见 `m.room.encrypted`，默认推送规则 `.m.rule.encrypted*` 在 DM 内逐事件 notify，invite/answer/hangup/candidates 全部计入 `unread_notifications`（客户端 `conversation_read_state.dart` 以服务器计数为权威）。
- 服务器不解密即无法区分信令与消息；向服务器提供明文违反 AGENTS.md E2EE 边界。生产 Synapse 分叉（媒体去重 + 登录兼容）无推送规则定制，无可配置项。
- 客户端治本（通话终态 `markRoomRead`，`matrix_e2ee_client.dart:1110`）已随 0.3.102/2144 发布；残余场景（通话中进程被杀 → 重启后信令未读滞留）的自愈设计列入批次 D（§5）。
- 总结中"BUG-19 服务端 m.call.* 过滤"条目系笔误：BUG-19（封禁 403）服务端修复已在 09-19 落地，与 m.call.* 无关。

## 结论二：生产 business-api 缺陷批次服务端修复曾丢失，已恢复（本任务实际部署）

- **根因**：2026-09-19 缺陷批次 B 的服务端修复以 docker cp 三文件覆盖部署；随后容器经两次更换（retired-room 修复 4996d6 → Mi6 限流修复 fb41d7fa，后者"基于在线镜像 + 仅 friendship.py 增量"构建），而 4996d6/fb41d7fa 的源码树为**陈旧且含未提交文件的工作树**（容器内 registration.py mtime 2026-09-03、CRLF 行尾、md5 不匹配任何 git 提交；identity.py 匹配 2026-09-12 提交 1f957444）→ 覆盖层随容器重建丢失。
- **恢复前核验（2026-09-20 12:4x +08）**：
  - BUG-19 `ACCOUNT_SUSPENDED`：容器内 0 命中（**丢失**）
  - BUG-12 `change_email`：容器内 0 命中（**丢失**）
  - BUG-21 `friend.accepted.merged`：modules/friendship/service.py 与 main md5 一致（在位）
  - BUG-11 `/blocks matrix_user_id`：service 层（service.py）在位；api/friendship.py 漂移与本修复无关
  - 红包限额：config 默认 20000（丢失），但 DB `app_settings.red_packet_max_total=200.00` 运行时覆盖在位（生产有效值 200 正常）
  - 全树漂移：容器 app/ 215 个 py 文件中 **77 个与 main 不一致**（结构性漂移，见 §风险）
- **恢复操作（admin 流程：备份→上传→SHA 门→docker cp→导入检查→重启→验证→固化）**：
  - 备份：服务器 `/opt/starchat/backup-20260920-defect-restore/`（0700，identity/registration/config 三原文件）
  - 覆盖文件：main @ 2525e63a 的 `api/identity.py`（SHA256 336DA69E…77ED7）、`modules/identity/registration.py`（A263C791…077E91）、`core/config.py`（91B3F28B…4D30A9）；与 340b6175 已测试版本逐字节一致（identity/registration 自 340b6175 后无改动，测试证据复用：服务端 pytest friendship 55 / identity 8 / email-change 3 全绿）
  - 上传 `/opt/starchat/restore-20260920/`，服务器端 sha256sum 与本地一致；docker cp 后容器内 `import app.api.identity / registration / config` = IMPORT_OK
  - `docker restart` 后 healthy；验证：换邮箱端点无 Idempotency-Key=422、带 key 不存在会话=400（EMAIL_VERIFICATION_INVALID）；登录错误密码（含 device 字段完整 body）=401 原口径；health 200；app-updates 未授权 401；近 5 分钟日志 0 error/traceback；14 容器 healthy 无变化
  - 固化：`docker commit` → **`starchat-business-api:defect-restore-20260920`（333c67272a72）**；运行容器仍为 fb41d7fa 镜像 ID + 覆盖层，重建时应改用上述 tag
- **残留风险（需用户决策，另立项）**：business-api 生产树与 main 存在 77 文件结构性漂移；只有从干净 main 重建镜像才能根治"重建丢覆盖层"。批次 D 计划 §7 已列建议，未获授权前不执行。

## CSV 审计与回填（已完成）

- 全部 41 项核对：仅 **BUG-28/35/40** 未修复（批次 D 计划已就绪）；BUG-03/38/39 的 CSV 状态滞后于代码（代码已随 0.3.102 发布，dca25721）；BUG-19/21/12 的部署状态已按本任务核验结果更新；BUG-23 补记决策。
- 更新行：BUG-03、BUG-12、BUG-19、BUG-21、BUG-23、BUG-28、BUG-35、BUG-38、BUG-39、BUG-40（共 10 行；状态列、批次列、提交列、备注列）。

## 生产发布渠道核验（只读）

- Android：`/opt/starchat/frontend/downloads/latest-arm64.apk` → `ChatFlow-0.3.102-build2144-arm64.apk`
- iOS OTA：`/opt/starchat/frontend/downloads/ios/manifest.plist` → `bundle-version 2144`
- 与上一批交付记录一致，未做任何发布动作。

## 交接与回退

- 回退：容器内三文件恢复命令 = 从 `/opt/starchat/backup-20260920-defect-restore/` docker cp 回原路径并重启；镜像级回退 = fb41d7fa718c（含限流修复，不含缺陷批次两文件）。业务数据/DB 无改动。
- 验证工件：`docs/verification/artifacts/2026-09-20/bug23-prod-verify/`（容器文件镜像副本、main 版本、覆盖文件、全树 md5 清单）。
- 下一条可执行操作：用户批准批次 D 计划 → 按 TDD 实施 BUG-28/35/40 + BUG-23 自愈；用户决策是否立项"business-api 干净镜像重建"。
- 运行中 CI/命令：无。未提交的本地改动：本任务新增文档 + CSV；工作树另有并行会话遗留改动（pubspec.lock、2026-09-19-defect-batch-a.md、GetUI lockfile），未触碰。
- 最后更新：2026-09-20T21:0x+08:00
## 批次 D 实施 + 生产镜像重建 + 新缺陷 E1/E2（2026-09-20/21，同日续）

### 1. 服务端：干净 main 镜像重建（用户已授权，完成）
- 前置落主干：并行会话当日生产部署的 caibi 储备策略增量（admin.py +17/ledger.py +3，与生产运行文件逐字节一致）先落 main（89606cad），`tests/business_api/admin` 17 绿 + identity+friendship 449 绿。
- 构建：`git archive main`（89606cad）→ 服务器 docker build → `starchat-business-api:main-clean-20260920`（08b0ea26）；镜像内 215 个 py 文件与 main 逐文件 md5 一致（215/215）。
- 迁移：生产 alembic head 0071 == main head → 启动 upgrade 空操作。
- 切换：复刻 caibi 冻结 compose 机制（仅换 image tag）。验证：healthy/live200/ready200；BUG-12 端点 422/400；错误密码 401；app-updates 401；ACCOUNT_SUSPENDED=1；grant_caibi=1；reserve_policy=2；红包限额 DB 200.00；traceback=0；基线 diff 仅 business-api；MOUNTS=3/ENV=63 不变。
- 回退：`docker compose -f /opt/starchat/releases/caibi-grant-20260920/candidate-frozen-private.json up -d business-api`（e347fd04）。
- worker 未动（漂移测量受 CRLF 噪音影响不精确；无已知缺失修复）。证据：`docs/verification/artifacts/2026-09-20/bug23-prod-verify/main-clean-rebuild-evidence.md`。

### 2. 批次 D 客户端（全部 TDD 红→绿）
| 项 | 修复 | 测试 |
| --- | --- | --- |
| BUG-23 残余自愈 | `MatrixConversationCapability._healCallSignalingTails`：快照观察到「尾部=通话终态信令（非 invite/candidates/negotiate）+ 服务器未读>0 + 非手动未读 + 房间未打开」→ 内联推进一次 read marker（(账号,房间,事件) 去重，失败重试） | call_signaling_unread_heal_test 4 绿（正常/invite 不触发/普通消息不触发/手动未读优先）+ 相邻 18 绿 |
| BUG-28 | 发送聚合点 `_sendMedia`→`ensureImageDimensionsForSend`（缺宽高时解码补齐 info.w/h，附缩略图路径不再缺尺寸）；展示侧 imageWidth/Height 回退 thumbnail_info | bug28_image_dimension_test 2 + adapter 套件（含新增回退用例）共 21 绿 |
| BUG-35（D5 不做暂停） | 协调器新增 `reportPreparationProgress`/`preparationProgressOf`/`videoWorkSummaryForRoom`；视频源转码 onProgress 接通；房间页死状态胶囊改为租约驱动的 summary 胶囊（转码百分比/上传中/失败可重试，覆盖相册+拍摄两路径） | bug35_video_send_progress_test 3 绿 + 协调器既有 25 绿 |
| BUG-40（D7 默认开） | `VoicePlaybackController` 自然播完（非暂停）→ 注入的 `nextAutoPlayVoice` 取同会话下一条未播语音自动播放；`VoiceAutoPlayPreferences`（SharedPreferences 持久化，默认开）+ 通知设置页开关 | bug40_voice_auto_play_test 5 绿（连播/关闭即停/无下一条/暂停不触发/失败不级联）+ 既有 17 绿 |

### 3. 新缺陷 E1/E2（用户本日报告，TDD 红→绿）
- **E1 低端安卓（MagicOS8.0/荣耀50Plus/Android14）群聊打字卡死**：根因=`_recordGlobalSearchIndex()` 每次时间线变化全量重建索引（O(N log N) UI 线程）。修复：`RoomSearchIndexScheduler` 增量（echo 只登记不提交）+ 400ms 去抖 + `GlobalSearchIndex.removeMessages`（撤回联动删除，防撤回内容可搜索）。bug_e1_search_index_incremental_test 3 绿 + search/room 套件 87 绿。
- **E2 红包/转账气泡闪烁**：根因=FinanceCardStore 挂 RoomPage State，每次进房间重建清零缓存。修复：`sessionFinanceCardStore()` 进程级共享、会话失效才重建。bug_e2_finance_card_cache_test 2 绿 + finance 全套 69 绿。

### 4. 门禁
- `flutter analyze lib test`：No issues found（7 个 lint 全部清零）。
- 全量 `flutter test --timeout 120s`：**3675 通过 / 0 失败（退出码 0）**。
- 提交：9a77f825（批次 D 全量，22 文件）；89606cad（caibi 储备策略落主干）。均已推送 origin/main（060097ef..9a77f825）。
- 并行会话未提交改动（frontend 管理页、pubspec.lock 等）未被纳入本任务提交。
## Mi 6 debug 2145 交付（2026-09-21，用户指令）

版本 0.3.103+2145（4cb19c83，契约门禁 PASS 已推送）。固定流程：debug arm64 源码构建（三项 HTTPS dart-define）→ Apktool 2.12.1 重建 → zipalign 36.0.0 -P 16 -f 4 → 固定身份签名（75b31c66…）→ 全门禁通过（aapt 2145/0.3.103；清单语义 0 差异；资产 339/339 identical；apksigner/zipalign PASS）。最终包 SHA256 `E6B85E2E…95E00`（145,297,707 字节）。

Mi 6（cbd0156b）`adb install -r` Success；设备回读 base.apk SHA256 与本地一致；firstInstallTime=2026-09-20 09:35:24 未变（数据保留）。待用户真机验收：E1 打字卡死、E2 气泡闪烁、BUG-40 连播、BUG-35 视频进度、BUG-28 尺寸、BUG-23 残余。证据：`docs/verification/artifacts/2026-09-21/mi6-debug-2145/`。
