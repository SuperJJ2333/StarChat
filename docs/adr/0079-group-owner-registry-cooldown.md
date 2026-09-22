# ADR-0079：业务群注册表与群主转让冷却（≥10 人须任满 30 天）

日期：2026-09-21。状态：**已批准（用户 2026-09-21 需求书确认全部规则）**。授权范围：实现与隔离测试；不含生产发布。

## 背景

业务库目前无群实体（群成员/权限以 Matrix 为权威，`groups/models.py` 仅存入群令牌）。用户批准群主转让冷却：冷却从**当前群主接任时间**起算；群实际 joined ≥10 时，当前群主必须**任满 30 天**（30×24 小时，服务端 UTC）才能转让；建群者接任时间 = 成为群主时间；成功转让后新群主接任时间 = 本次转让成功时间；**达到 10 人不重置接任时间**；不足 10 人不因本条新增限制（既有权限要求保留）；人数含群主、不含待接受邀请。

## 决策

1. **业务群注册表** `business_groups`（迁移 expand-only）：`room_id PK`、`owner_user_id`（业务 user id）、`owner_since TIMESTAMPTZ NULL`（NULL = 任期无法证明）、`tenure_source TEXT NULL`（`creation|transfer|admin_migration`）、`created_at/updated_at`。注册表是**财务受益人与任期的权威来源**；Matrix 权限仍是房间操作控制的权威。
2. **注册来源**：
   - 新群：客户端建群后调用 `POST /groups/register`；服务端经 Matrix 网关核验发起者当前 power level ≥100（创建者口径）后落行，`owner_since=now`、`tenure_source='creation'`。
   - 旧群被动发现（红包创建、群接口首次触达）：经 power levels 解析群主落行，`owner_since=NULL`（**不**用最近活跃时间、**不**随意填 30 天前——任期不可证明即记 NULL）。
   - 例外通道：`POST /admin/groups/{room_id}/owner-tenure`（管理员，强制原因，审计）设置可证明的接任时间（`tenure_source='admin_migration'`）——对应"需用户决定的例外"，逐案人工核证后由管理员录入。
3. **转让端点** `POST /groups/{room_id}/transfer-owner`（请求者为注册表群主 + 现有群管权限）：
   - joined ≥10：要求 `owner_since` 非 NULL 且 `now − owner_since ≥ 30×24h`（服务端 UTC 精确比较，UI 再转时区）；否则 409 `OWNER_TENURE_INSUFFICIENT` / `OWNER_TENURE_UNPROVEN`。
   - joined <10：不施加 30 天限制，保留既有权限要求。
   - **并发单次成功**：`UPDATE business_groups SET owner_user_id=:new, owner_since=:now WHERE room_id=:room AND owner_user_id=:old_owner`——行锁 + 条件更新保证并发转让只有一个赢家；失败/超时/重试不提前变更接任时间（接任时间与所有权同一事务写入）。
   - 业务与 Matrix 原子协调：注册表更新与 Matrix power level 变更在同一请求内完成，Matrix 变更失败则业务事务回滚（不产生"业务已换主、Matrix 未换"的分裂）；Matrix 网关不可达时转让失败、原状保留。
4. **Matrix 绕过防线（权威关系）**：直接改 Matrix 权限**不能**变更注册表 `owner_user_id`/`owner_since`——因此不能绕过冷却获得"新群主任期"，也**不能**改变抽成受益人（ADR-0078 的受益人在红包创建时从注册表锁定）。群信息接口同时返回注册表群主与 Matrix power level 群主，二者不一致时标记 `owner_desync=true` 供管理员核查（只读告警，不自动改写）。
5. **人数口径**：joined 成员数取自服务端权威快照（与红包成员快照同一 `creation_snapshot` 口径）：含群主、不含 invite/ban/leave。成员数与身份由服务端核验，不信任客户端输入；禁用按钮只是 UI，不是权限边界。
6. **已知规避空间（如实记录，不擅自加规则）**：群主可先退出部分成员使 joined <10 完成转让再拉回，从而绕过 30 天限制。用户明确未批准"曾经满 10 人即永久限制"类规则，本 ADR 不实现；如需堵住须另行批准。
7. **不改动**：现有群管权限模型（moderator ≥50/invite）、入群令牌/审批、Matrix 房间权威成员关系、红包成员授权（F06）。

## 迁移与回退

- `0075_business_groups` 建表 expand-only；无破坏性变更。
- 回退：转让端点下线即停止新转让；注册表保留作为抽成受益人依据；冷却参数（30 天/10 人阈值）集中常量，调整需 ADR 修订。


## 实施补充（2026-09-21，复审缺口闭环）

**持久转让协调流程**（`group_transfer_intents`，迁移 0080；`GroupTransferCoordinator`）：转让是持久阶段机而非单事务声明——T1 建意图（领域校验：joined/任期/身份/唯一权威群主）→ T2 认领（条件 UPDATE + 随机 claim_token，防过期持有者写回）→ 事务外以 **Synapse admin login-as-user**（网关既有能力，invite 链路在用）换取短期用户 token、以当前群主身份发送 `m.room.power_levels`（新群主=100、旧群主降权）→ T3 **权威房间状态读取**确认 → T4 条件换主（WHERE owner=预期旧群主）+ owner_since=now + COMPLETED。失败/未确认回 VALIDATED 重试（≤3 次），超限 NEEDS_REVIEW（不擅自回滚 Matrix 事实）；崩溃恢复：MATRIX_PENDING 认领超时先读权威状态短路（已应用→直接完成，不重复发送）。重复请求幂等重放、载荷变更 409；并发转让条件更新单赢家；只有 COMPLETED 才报告新群主。

**安全隔离保持**：`BUSINESS_GROUP_TRANSFER_COORDINATION_ENABLED` 默认 `false`＝端点维持 503 GROUP_TRANSFER_UNAVAILABLE；恢复 worker 仅在配置齐备时装配。启用前置条件：规格符合性与质量/安全审查记录、故障注入套件（`test_group_transfer_coordination.py`）全绿、生产网关真实演练。已知残余：旧客户端直接改 Matrix power levels 的路径不受本协调约束（只能靠 desync 观测发现），完整治理需后续产品决定。

## 第二轮复审修正（2026-09-22，覆盖上文自动重试与原子协调表述）

- HTTP/Matrix 与 SQL **不构成原子事务**。默认端点和恢复 worker 均受同一关闭开关约束。本轮未批准启用。
- 每房间至多一个未决意图；NEEDS_REVIEW 同样阻止新意图。认领前核对请求者、当前唯一群主、目标 active/joined 与任期；应用前重查，完成前再读取权威状态。保留整个 power_levels 事件，仅修改旧/新群主 user 条目，新群主继承原群主级别，不能清空 events/defaults 等 ACL。
- **发送后异常或确认不明确保留 MATRIX_PENDING，不退回 VALIDATED 自动重发**。认领过期后的恢复只读确认，证实已应用才完成；不能证实则 NEEDS_REVIEW。只有能确定尚未发送的准备失败可有限重试。claim token 防止过期持有者写回。
- 本地阶段锁、最终条件更新与再次读取降低并发风险，但无法消除 Matrix 外部修改与 SQL 提交间的竞态，也不能阻止旧客户端直接改权限。真实网关演练、未决意图人工处置流程与旧客户端治理尚未完成，不能将本轮测试称为“生产一致性完全闭环”。
- SQLite 故障注入与 PostgreSQL 16 并发/锁顺序专项已补，详见第二轮复审报告；未触达生产 Matrix。

## 第三轮处置接口复审（2026-09-22）

- `confirm_applied` 核实权威新群主后，持锁推进 MATRIX_APPLIED，更新 claim token 隔离旧回调并落复核人审计，再走既有 complete 的再次确认与条件换主。重放与审计后崩溃重试不得重复换主或重复复核审计。
- **旧群主当前仍持权不能证明先前请求永远不会生效。** `fail_unapplied` 仅允许有持久“发送前失败”证据的意图释放：协调器确定在发送前终止时清除两项 claim 标记；未知发送保留标记，不能以等待时间或单次旧权限快照释放。新安全终态使用 REVIEW_CONFIRMED_NOT_SENT；旧版不安全 FAILED 继续隔离，不自动当作可重新发起。
- 晚到失败/成功回调必须同时匹配 token 与 MATRIX_PENDING 阶段；完成或复核后不得复活意图。
- 管理复核写接口同样受默认关闭开关约束，先核对 ACTIVE 操作者与 SYSTEM_ADMIN。开关关闭不能通过复核接口间接变更注册表。
- 权威读取成功但没有唯一最高权限群主（包括并列最高权）标记 owner_desync；读取失败通过 `owner_authority_available=false` 表示未知。不能把解析为空当作权限一致。
- 隔离真实 Synapse 已实测非默认 ACL 完整保持、真正拒绝旧群主再转让、旧客户端并列改权的 desync，以及实际写成功后注入返回丢失的复核（只发送一次）。测试绑定 loopback、必需环境失败不得伪装 skip，容器和测试密钥目录 finally 清理。仍不证明生产和任意外部改权竞态完全闭环，保持开关关闭。
