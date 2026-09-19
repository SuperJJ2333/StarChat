# 已退出私聊房间的定向修复

适用于已明确授权、人工确认的单个好友 pair：规范发送房间已退出，而双方已有一个合格且已登记的加密历史房间。依据 [本次任务](../workflow/tasks/2026-09-19-retired-direct-room-repair.md)、[批准计划](../superpowers/plans/2026-09-19-retired-direct-room-repair.md)和 [ADR 事故修订](../adr/2026-09-19-recoverable-direct-room-alias.md)。本手册不代表部署或设备验收已经完成；实际门禁与执行状态以任务证据为准。

## 操作入口与严格证据

仅在受控运维环境调用已配置的 `FriendshipService` 公共方法；没有 HTTP 入口。调用方负责运维身份认证，传入实际操作人，不能冒充用户：

```python
service.repair_retired_direct_conversation(
    operator_id=actual_operator_id,
    actor=business_user_id_a,
    peer=business_user_id_b,
    expected_old_room_id=confirmed_old_room_id,
    target_room_id=confirmed_registered_target,
    idempotency_key=stable_incident_operation_key,
)
# 返回 conversation_id、matrix_room_id、previous_room_id
```

人工选择 pair 和目标，禁止按超时、活跃度或自动扫描批量选举。执行前确认当前规范房间与 `expected_old_room_id` 相同、好友关系存在且双方无屏蔽。目标必须是此 pair 已登记的历史来源；新取 Matrix 状态必须证明恰好双方 JOIN、没有额外非 leave 成员，并启用 `m.megolm.v1.aes-sha2`。旧房间 admin detail 必须成功且 room_id 匹配，`joined_members` 必须是严格整数 0；严格 state 请求也必须成功，成员状态只能为 leave（空 state 可以）。404、缺字段、布尔/字符串计数、未知或畸形状态均拒绝，不能作为退休证据。

方法在 pair lock 内重新取证并 CAS；取证后再次查询双向屏蔽。普通 block 写入不共享此锁，最后一次屏蔽查询至提交之间仍有竞态窗口；Matrix 成员变化也不与业务事务原子化。不得声称消除了这些窗口，修复也不授予 Matrix 成员资格或绕过正常发送权限检查。

## 上线门禁与执行

1. 重新确认线上镜像和源码输入，构建受审候选并记录镜像 digest、两源码 SHA256、测试输入与时间。不得拿历史候选 hash 代替当前核对。
2. 保存当前 API 镜像/源码/配置的受保护回退证据及数据库备份，验证隔离恢复；真实身份、房间 ID、凭据和原始日志留在受控主机，不提交仓库。
3. 通过定向红绿回归、规格审查、独立质量安全审查及适用仓库门禁；使用候选在隔离 PostgreSQL 验证并发 CAS、同键回放零新增、失败事务回滚、取证期间新增 block 拒绝。SQLite 单测不能代替 PostgreSQL 门禁。
4. 仅按授权部署 API 候选；无新增迁移。以新鲜元数据再次核对人工选定 pair，再用固定幂等键调用一次公共方法。响应不明时重用完全相同参数和键，不改键重试。

## 审计、幂等与回退

规范业务 conversation ID 保持不变，旧房间保留为历史来源；已有 reservation 的 owner/attempt/alias 不改。若原先没有 reservation，pair lock 可以创建受 fence 保护的 reservation，不承诺零新增 reservation。

实际 operator、排序后的 pair、旧/新房间及固定 reason `DIRECT_ROOM_RETIRED_REPAIR` 绑定请求摘要。成功事务同时写入 `friend.direct_room_repaired` 审计（before/after）、事务 Outbox 和 scope `friend.direct.retired.repair` 的完成幂等记录。同键同请求返回原结果，无新增审计/Outbox/历史关联；异参拒绝。新键遇到已经改变的 canonical 应 CAS 拒绝，不能冒认首次成功。

代码回退仅恢复受审旧 API 镜像，保留已提交的规范映射、来源、reservation fence、审计及幂等记录。不得删除审计或恢复整库来撤销单次纠正，也不得直接 SQL 改回旧房间。任何反向修复须另行授权、重新取证和审查；原旧房间仍退休时不能满足目标条件。事务内失败应整笔回滚，先读回确认，不手工补写部分表。

## 读回与客户端验收

执行后独立读回两个公共查询：`direct_conversation(actor, peer)` 与 `direct_conversation_associations(actor, peer)`。两者都须返回目标 canonical；后者的 `room_ids` 须包含旧房间和目标房间。再核对稳定 conversation ID、操作人及 before/after、完成幂等结果和对应 Outbox；相同请求回放后行数不增加。

Android 0.3.97+2136 用户等待同步后退出并重新进入该好友会话，发送一条**新文本**，确认接收端实际收到。既有失败或结果不确定消息保持原 room/transaction ID，禁止 retarget 或原样重放进新目标；点击旧红泡不能替代新发送验收。不清本地数据，不强制加入/删除房间，不读取消息明文或密钥。设备收发成功必须以实际反馈确认，服务器元数据读回不等于真机验收。
