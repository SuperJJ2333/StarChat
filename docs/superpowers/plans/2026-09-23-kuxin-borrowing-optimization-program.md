# 实施计划：酷信源码借鉴优化专项（资金安全 / 容灾开关 / 性能缓存 / 拥挤场景）（2026-09-23）

状态：基于 2026-09-21～09-23 对酷信（视酷 SkWeiChat）源码与 TTTalk APK 的逆向分析产出；**本文为排期草案，每阶段开工前需按惯例补对应 ADR 并获用户批准**。
建议 ADR：0080 抢红包 Redis 预拆分 · 0081 多服务器容灾与 config 下发 · 0082 TOTP/设备管理/社交恢复 · 0083 E2EE 群已读聚合 · 0084 推送合并窗口。
任务记录：`docs/superpowers/tasks/2026-09-23-kuxin-borrowing-optimization-program.md`（开工时建立）。

## 文件所有权（各批独占；并行任务另起工作树）

服务端 `services/business-api/app/modules/{redpacket,security,appconfig,receipts}/`（security、appconfig、receipts 为新模块）、`migrations/versions/0084..`、`services/business-worker/app/tasks/**`、`services/getui-bridge/**`。客户端 `apps/mobile_flutter/lib/core/{cache,outbox,config}/`、`lib/features/{matrix,settings,moments,push}/`。SDK 补丁 `third_party/matrix/**`（批次内单独提交并记录 CHATFLOW_PATCH.md）。工具 `scripts/loadtest/**`、`tests/business_api/**`。

## 阶段一：资金与账号安全（P0，约 12～15 人日）

1. **抢红包引擎重做（Redis 预拆分 + Lua 原子抢）**：`modules/redpacket/` 保持 API 形状不变，内部换引擎。发红包：拆 N 份 → `RPUSH rp:{id}:packets` + 元数据落 Postgres（`0084_red_packet_redis_engine`，state=ACTIVE）；抢：单 Lua 脚本原子完成 `LPOP` + 已领集合 `SADD` + 判空；领取凭证写 Redis Stream，`business-worker/app/tasks/red_packet_settlement.py` 异步落 ledger（复用 0078 抽成与 FORFEITED 退款逻辑，claim 幂等键 `(packet_id, user_id)` 唯一约束）。Redis 不可用时**拒绝抢（fail-closed）**，绝不允许绕过 Redis 直改账本。测试：500 并发抢 10 份恰 10 成功、重复请求幂等、并发退款与最后一件竞争、sum(claims)==总额对账、Redis 宕机 fail-closed、抽成比例边界与 0078 用例全量回归。
2. **TOTP 两步验证**：`modules/security/totp.py`（pyotp）+ `0085_user_totp`（secret 用应用密钥加密落库）。端点：setup（otpauth URI）、enable（验码启用）、disable（密码+当前码双因子）。挂接点：提现、换绑、改支付密码、信任新设备。测试：±1 时间窗、重放拒绝、未启用时敏感操作不受影响、错误码限流、恢复码一次性。
3. **设备管理与登录历史**：`0086_user_devices`（devices + login_events 两表）。登录登记设备指纹；`GET /security/devices`、`POST /security/devices/{id}/revoke`（调 `integrations/matrix_admin.py` 吊销该设备 access_token）；登录历史分页（IP/UA/结果，脱敏）。测试：新设备事件产生、revoke 后 Matrix token 确失效、历史脱敏、分页边界。
4. **好友辅助找回（社交恢复）**：`0087_recovery_contacts`（owner+friend+status，N 选 M）。流程对齐酷信 VerifyFriendHelp：发起 → 好友逐个确认（时效链接）→ 满足 M 票后允许重置密码并信任新设备。好友资格 = 双向好友且注册 ≥30 天。测试：M-of-N 边界、资格校验、链接时效、单好友重复投票、全程审计日志。

## 阶段二：容灾与运营开关（P0，约 6～8 人日）

5. **config 下发中心**：新模块 `modules/appconfig/`，公开端点 `GET /api/v1/config` 一次下发：`feature_flags`（红包显示、注册开关、邀请码、朋友圈入口等）、`server_list`（homeserver 候选+区域）、`sync_timeout_ms`（Matrix long-polling 参数）、`force_update`（min_version+url，衔接现有 `api/app_update.py`）。开关存 DB + admin 编辑端点，Settings 校验互斥项。测试：默认值、开关 TTL 后生效、未配置字段省略、admin 权限。
6. **客户端容灾探测**：`lib/core/config/` 启动拉取 config 并持久化上次成功配置；多 endpoint 并发轻量探测→测速排序→故障自动切换；切换事件上报 `/api/v1/console/fault-report`（对齐酷信 faultCommit 思路）。matrix `/sync` timeout 从 config 读取。测试：探测排序稳定、首台失败自动下一台、全部失败回落缓存配置、上报不阻塞。
7. **隐藏诊断入口**：设置页连点版本号 7 次 → 运维面板（当前服务器/延迟、切服务器、清缓存、**重建本地 SDK 库**——对齐酷信 About 页 rebuildDatabase）。诊断操作全部需二次确认。测试：入口触发、重建后自动重新 sync、清缓存不影响 E2EE 密钥库。

## 阶段三：性能缓存与数据库（P1，约 10～13 人日）

8. **图片解码降采样 + 缓存分桶（Flutter）**：封装 `ChatNetworkImage` 强制 memCacheWidth/Height；`core/cache/` 拆三个 CacheManager：avatar（小/久）、chat_media（中/30d）、moments（大/14d，LRU 上限独立）；RAM<4GB 设备下调 `imageCache.maximumSizeBytes` 且 GIF 表情不自动播放。测试（widget test）：降采样参数传递、分桶 TTL、低端机分支。
9. **视频边下边播 + 预加载（Flutter）**：聊天/朋友圈视频走 flutter_cache_manager 预取首屏 1-2MB 再播放（暂不引入 media_kit，控制依赖）；moments 列表滚动方向预取队列。测试：二次播放命中缓存、预取不阻塞 UI 线程、失败回退流式。
10. **matrix SDK 数据库补丁（vendored）**：`third_party/matrix` 事件表补 `(room_id, origin_server_ts DESC)` 复合索引（SDK schema 版本号递增，升级路径不丢数据）；同步批次合并单事务提交；新增按房间保留最近 N 条的清理任务（后台周期）。每项补丁记录进 CHATFLOW_PATCH.md。测试：索引存在、旧库升级幂等、清理保留阈值、事务批量与逐条写入结果一致。
11. **outbox 补齐**：重发上限（3600s 或 5 次先到为准）→ 转 failed 待手动重试（对齐酷信 maximumResendDuration）；附件上传进度持久化、杀进程恢复（衔接 `attachment_upload_controller.dart` 与 content-addressed 去重，服务端无秒传接口故不做服务端秒传）。测试：到上限停止、进度恢复、进程重启续传。
12. **E2EE 群已读聚合**：新 `modules/receipts/`：客户端攒批上报已读（对齐酷信 SendReceiptManager），服务端 Redis `INCR` 聚合计数 + 定期落库（`0088_room_read_aggregates`）；策略：≤20 人群维持原生逐人 receipt，以上仅聚合数「N 人已读」。测试：上报幂等、计数准确、阈值切换边界、隐私断言（聚合接口不可反查个体）。
13. **推送合并窗口**：`getui-bridge` 前置 Redis debounce（`room+user` 3s 窗口计数合并，文案「N 条新消息」；不同房间不合并；窗口结束即推）。测试：合并、跨房间隔离、单条零延迟、bridge 宕机恢复。

## 阶段四：验证与延展（P2，持续）

14. **压测基线**：`scripts/loadtest/`（k6）：场景 A 千人群 50msg/s×10min（sync 延迟 P95）；场景 B 500 并发抢 10 份红包（恰 10 份、P99）。基线报告入 `docs/verification/`。
15. **掉帧监控（Flutter）**：`SchedulerBinding.addTimingsCallback` 采样 jank 率，批量上报 `/api/v1/diagnostics/jank`，按机型档位聚合。
16. **P2 功能池**（逐个独立立项）：扫码登录（Synapse `m.login.token` 流程打通 Web 端）、群公告已读列表、群助手规则化（扩展现有 matrix-bot 为房间级关键词自动回复）、消息翻译代理、个人收付款码。

## 发布顺序（每阶段独立可发布，需另行授权）

阶段一：红包引擎（灰度开关 `feature_flags.redpacket_redis_engine`，新旧引擎可回切）→ TOTP/设备/社交恢复（纯增量）。阶段二：config 中心 → 客户端探测（旧服务端无 config 时全默认值兼容）。阶段三：客户端性能批可随时发；SDK 补丁需全量回归 E2EE 用例后发。回退：红包回切旧引擎+对账冲正、feature flags 独立开关、SDK 补丁版本回退（本地库 schema 前向兼容）。

## 明确不做

不引入 `synchronized`/单机锁语义的红包实现；不学 largeHeap、三进程互拉保活、明文 HTTP、客户端可逆密钥下发、MD5 存密码（酷信反面教材，分析报告见会话 2026-09-23）；不在无 ADR 前动资金模块；不因压测修改生产数据；不做服务端秒传（Synapse 无原生接口，收益不抵风险）；已读聚合不存储任何可反查个体的明细。
