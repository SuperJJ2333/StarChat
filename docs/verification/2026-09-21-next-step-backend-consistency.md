# 验证记录：下一步批次 1（后端一致性与发布前阻断项）+ 批次 2（后台三页）

任务：执行 [2026-09-21-zcode-next-step](../workflow/prompts/2026-09-21-zcode-next-step.md)。
前置：独立复审（[2026-09-21-pricing-code-review](2026-09-21-pricing-code-review.md)）回填 40 文件后的主工作区。
授权边界：不部署生产、不发送真实短信、不做真实资金操作、不改生产数据。

## 一、状态总表（严格区分层级）

| # | 事项 | 已实现 | 已测试 | 未完成 / 未发布 |
| - | ---- | ------ | ------ | -------------- |
| 1 | 阿里云短信适配器（`dypnsapi` SendSmsVerifyCode/CheckSmsVerifyCode，供应商生成码） | ✅ `app/modules/identity/sms_aliyun.py` + Settings + 装配 + pyproject 依赖钉版 | ✅ 12 项（替身注入，无真实调用）；供应商校验路径 13 项手机回归全绿 | **真实 SDK 安装、真实通道发送/验收未做**；`SMS_PROVIDER_UNAVAILABLE` fail-closed 已测 |
| 2 | 充值案件 ↔ 财务执行持久绑定（迁移 0079 `recharge_credit_bindings`）+ worker 宕机恢复登记 | ✅ bind/complete_bound/sweep + 管理端点 + worker 接线 | ✅ 5 项绑定套件 + 既有 7 项充值回归；冲正后登记拒绝、幂等、双端唯一 | 生产数据未动 |
| 3 | 群主转让持久协调（迁移 0080 `group_transfer_intents` + `GroupTransferCoordinator` + 网关 login-as-user/状态发送 + 恢复 worker） | ✅ 阶段机 VALIDATED→MATRIX_PENDING→MATRIX_APPLIED→COMPLETED/NEEDS_REVIEW；权威状态短路恢复；条件换主单赢家 | ✅ 8 项故障注入（网络失败重试、发送后崩溃短路、未确认不换主、并发、幂等/冲突、冷却前置） | **端点默认保持 503 隔离**（`group_transfer_coordination_enabled=false`）；生产网关真实演练未做；旧客户端直改 Matrix 权限路径不在本协调约束内（见 ADR-0079 实施补充残余） |
| 4 | 后台三页（充值案件/客服目录/汇率与储备三类数量） | ✅ `frontend/src/admin-recharge-panel.js` + admin-home 注册 + admin-api 客户端方法 + `GET /recharge/admin/reserve-valuation` | ✅ 5 项 node 测试；frontend 全量 **227 passed / 0 failed** | 未构建发布静态资源 |
| 5 | OpenAPI 重导出 | ✅ | ✅ `--check` PASS | — |
| 6 | ADR 实施补充 0075/0077/0079 | ✅ | —（文档） | — |
| 7 | Flutter 批次 3 | ❌ **未完成**（见第五节） | — | — |
| 8 | 500 人群压测 / 真机 / 生产验证 | ❌ 明确不在授权范围 | — | — |

## 二、批次 1 关键设计（对应复审三大缺口）

1. **转让协调**：HTTP 与"Matrix 权限 + 财务换主"不是同一事务 → 持久阶段机；Matrix 侧经网关**既有能力**（`POST /_synapse/admin/v1/users/{id}/login` 换短期 token——invite 链路已在用）以当前群主身份发送 `m.room.power_levels`，成败以随后的权威房间状态读取为准；T4 条件更新注册表（WHERE owner=预期旧群主）保证并发单赢家；崩溃恢复对 MATRIX_PENDING 先读权威状态短路（已应用→直接完成，不重复发送）。任何阶段不向客户端虚假成功；只有 COMPLETED 才报告新群主。
2. **充值绑定**：案件与财务调整双向唯一绑定（`state_active` 判别的部分唯一）；绑定校验归属/未冲正/在审批中；执行后 worker 幂等登记，**完整复用 mark_credited 凭证核验**（已执行、用户、金额、分录、冲正状态）；调整被拒/凭证不符 → 绑定 FAILED 原因入档、案件保留 SUBMITTED 供人工准确结算；绝不伪造 CREDITED、绝不二次入账、后台不得重建调整补登记。
3. **阿里云短信**：用户指定 `alibabacloud_dypnsapi20170525` 验证码短信——供应商生成验证码（`##code##` 占位、`min` 分钟有效），`CheckSmsVerifyCode` 权威校验；`PhoneOtpService.code_verifier` 注入路径替代本地哈希比较，尝试计数/用途绑定/单次消费不变；供应商不可达异常=事务回滚=不计尝试不消费；配置不完整拒绝启动；SDK 惰性导入、未安装明确失败；凭据仅 SecretStr 进 SDK。

## 三、规格符合性审查（本批）

- 未改变任何用户确认的金额规则：1 点钻=1 CNY、余额不动、外部 USDT、0.5%/0.1%、满 10 人仅群主本群免手续费与转让任期检查。
- 汇率纪律：full_backing 有点钻负债而无新鲜报价 fail-closed（复审修正保留）；过期参考不用于自动资金结算；绑定完成时的 `final_rate` 反推不精确即转人工（不伪造）。
- 财务四件套：绑定/登记/转让完成/兑换关闭均带幂等键、稳定 reason code（`RECHARGE_BIND`、`RECHARGE_CREDIT`、`GROUP_OWNER_TRANSFER`）、actor、审计 + Outbox（`recharge.bound`、`recharge.credited`、账本自身事件）。
- 权限：bind/complete/reserve-valuation 要求 `FINANCE_REVIEW`/`SYSTEM_ADMIN`（RBAC 服务端校验）；目录仍 SYSTEM_ADMIN。

## 四、质量/安全审查（本批）

- **注入面**：转让的网络 I/O 全部在业务事务外；失败路径以权威状态读取为准，不信任发送返回值。
- **防重放/并发**：意图幂等键唯一 + 载荷摘要冲突；claim_token 条件写回（过期持有者写回被拒）；绑定/登记 `INSERT RETURNING` 式认领（沿用复审修正）兼容 PostgreSQL。
- **PII/凭据红线**：适配器错误与 `describe()` 不含 AK/SK/完整号码（有测试）；OTP 仍只存哈希或交供应商；Outbox 只存挑战 ID。
- **E2EE 边界**：短信登录/换绑不触及 Matrix 密钥；转让协调只操作房间状态，不接触消息内容。
- **失败开放检查**：`fresh_usd_cny_rate` 缺表容错＝按无报价 fail-closed（复审语义保留，修复 SQLite 测试元数据崩溃）。
- 遗留风险（如实）：转让协调默认关闭下的 desync 只能观测不能阻断；NEEDS_REVIEW 需人工裁决流程（后台入口下一批）。

## 五、Flutter 批次 3 —— 未完成（如实）

本轮预算全部投入批次 1/2，Flutter 未动工。需要的入口与契约（已在 OpenAPI 冻结）：注册 `channel=phone` + `/auth/phone/*`；`GET /support/recharge-directory`（若未实现则先补目录用户端点——`GET /api/v1/recharge/directory` 已存在）；钱包 `user_conversions_closed`/`caibi_pricing_version` 投影；红包 `fee_exempt/commission_status/commission_amount`；提现 `final_receive/final_rate/rate_stale`；转让 `stage` 语义（UI 不得在非 COMPLETED 显示新群主）。后续批次须按仓库 UI 交付流程（demo/registry/UI 契约门禁）执行。

## 六、门禁与证据（本轮新增）

| 范围 | 命令 | 结果 |
| --- | --- | --- |
| 阿里云短信 | `pytest tests/business_api/identity/test_aliyun_sms_adapter.py` | 12 passed（替身，无真实调用） |
| 手机回归 | `pytest tests/business_api/identity/test_phone_auth.py` | 13 passed |
| 充值绑定 | `pytest tests/business_api/recharge` | 12 passed |
| 群转让协调 | `pytest tests/business_api/groups` | 44 passed（含 8 项故障注入） |
| worker | `pytest tests/business_worker` | 111 passed |
| frontend | `npm test` | 227 passed / 0 failed |
| OpenAPI | `export_openapi.py --check` | PASS |
| 后端全量（第 1 轮） | `pytest tests/business_api tests/business_worker -q` | 2365 passed / 3 failed（迁移头钉×2 未含 0080、OpenAPI 契约文件落后于新增端点）→ 全部为门禁钉值/契约再导出问题 |
| 头钉与契约修复后 | `pytest tests/business_api/test_migrations.py tests/business_api/test_wallet_release_baseline.py tests/business_api/test_openapi_contract.py -q` | 19 passed；`export_openapi.py` 已重写并 `--check` PASS |
| 完整 verify.ps1 | `pwsh -NoProfile -File scripts/verify.ps1`（日志 `artifacts/2026-09-21/next-step/verify-full.log`、exit 码 `verify-exit.txt`） | **exit=0（`Verification: PASS`）** |

环境：py 3.12、Windows、`PYTHONPATH=services/business-api;services/business-worker/app;.`（verify 同口径）。PostgreSQL 专项（迁移 0001→0078 实库、并发、32 并发申请单）由复审轮完成，本轮未重复同口径实测；本轮新增迁移 0079/0080 的实库演练在 verify Alembic 步骤（SQLite/离线 SQL）与复审方法之间，生产部署前仍须按复审的 PG 演练方法重跑 0001→0080。

## 七、下一步

1. 复审后的转让协调端点在生产网关演练 + 用户批准后启用配置。
2. NEEDS_REVIEW 人工裁决后台入口；充值案件页接 worker 恢复展示。
3. Flutter 批次 3（按第五节契约入口）。
4. 真实短信通道开通与发送验收（凭据入生产配置，不入仓库）。


## 八、最终门禁追记（2026-09-21）

`pwsh -NoProfile -File scripts/verify.ps1` **退出码 0**（`artifacts/2026-09-21/next-step/verify-full.log`，174 行；`verify-exit.txt`=`exit=0`）。分段：仓库/部署策略 PASS、模板 PASS、Infra **143 passed**、Getui **28 passed**、Matrix Bot **9 passed**、business_api+business_worker **2368 passed / 58 skipped**（含本轮全部新增与修复用例）、Flutter boundary（tests/mobile）**84 passed**、Business API import PASS、AST、**Alembic 迁移链演练 `Alembic migrations: PASS`**（含 0079/0080 新迁移）、**OpenAPI contract PASS**、Compose render。脚本内任何门禁失败都会以非零退出；本次 exit=0 即全部门禁通过。58 个跳过项按复审口径保留为未验证（需显式 PostgreSQL/环境开关的场景），生产部署前须按复审 PG 演练方法对 0001→0080 重跑实库迁移与并发。

未宣称事项（继承复审纪律）：真实短信通道未开通；Flutter 批次 3 未动工；转让协调端点默认关闭；无端到端真机；未部署生产。
