# 2164群主转让修复与启用前证据

时间：2026-09-23 20:20 +08。子任务基线 e8bf144046535d1c90e44dcd185c3fea0c0aeff4，工作树 `.worktrees/debug-feedback-2164`。用户已要求恢复服务器转让；本子任务只读生产，发布由根任务整合。对应[当前计划](../superpowers/plans/2026-09-23-debug-feedback.md)、[ADR-0079](../adr/0079-group-owner-registry-cooldown.md)。

## 根因与最小修改

- `GET /groups/{room_id}/transfer-intents`已存在，旧群未有注册表记录时返回404 `GROUP_NOT_REGISTERED`；客户端将全部404归类为服务器不支持。API现在对未登记群复用owner接口的ACTIVE账号、当前joined成员校验和权威`ensure`登记。登记只认唯一最高权限且ACTIVE/joined的业务群主，任期保持NULL；现有记录不重新推导群主。时间线仍只开放给登记群主或SYSTEM_ADMIN。
- Flutter区分群业务404与缺接口404，前者明确提示核验登记资料，后者保留旧服兼容；无伪造成功/空记录、无本地改Matrix权限。
- 转让协调开关线上仍为false。默认关闭不改变；部署需显式启用API和worker同一开关。
- 满10人且任期未知仍409 `OWNER_TENURE_UNPROVEN`，文案说明联系管理员凭接任证据补录、核实任满30天才可转让。不满10人不额外增加任期限制。

生产源码覆盖白名单只有 `services/business-api/app/api/groups.py`、`services/business-api/app/modules/groups/transfer_coordination.py`。Flutter两文件、后端两测试文件不进生产镜像覆盖。无迁移/配置默认值/认证模型修改。

## Fresh只读生产观察

本轮通过主仓`scripts/starchat-server.ps1`/jumper读取：API ba801c6c2682，worker07019a1b76d1；schema `0087_support_payout_workflow`；business_groups=1、group_transfer_intents=0。API Settings协调false，Matrix URL和admin凭据已配置（只输出布尔值）。当前API Compose标签指向 `/opt/starchat/releases/staff-direct-settlement-20260923/candidate-api-private.json`。不把这些观察替代发布前最终漂移检查；根任务另存live-sources.json。未查询消息/密钥，未改变真实群权限或执行真实转让。

## 测试证据

Windows/PowerShell7 UTF8，Python3.12.10。输入SHA见[清单](artifacts/2026-09-23/debug-feedback-transfer/input-hashes.json)。测试终端输出由本会话工具记录；未编造落盘完整日志。

| 命令/场景 | 结果 |
| --- | --- |
| `py -3.12 -m pytest tests/business_api/groups/test_group_registry_api.py -q`（修复前） | 4 failed/1 passed，均为实际404与期望200/403/503不符，exit1 |
| 同文件9/10人API联测（文案修复前） | 6 passed/1 failed，10人真实409但无管理员下一步提示，exit1 |
| `py -3.12 -m pytest tests/business_api/groups --ignore=tests/business_api/groups/test_synapse_transfer_integration.py -q`（最终） | 70 passed，36.74秒，exit0 |
| `SYNAPSE_TEST_REQUIRED=1 py -3.12 -m pytest tests/business_api/groups/test_synapse_transfer_integration.py -q` | 3 passed，93.71秒，exit0，无skip |
| Flutter `group_chat_info_test.dart`新增缺注册错误分类 | 原实现failed1/exit1；修复后整文件30 passed/exit0 |
| Flutter analyze两修改文件 | No issues/exit0，3.2秒 |
| 隔离PostgreSQL16.9并发探针 | 16转让请求1意图/15冲突、1次权限发送；持意图锁同键重放无倒置等待；16旧群并发发现1注册行/任期NULL，11个安全重试，exit0 |
| 定向git diff --check | exit0 |

真实Synapse固定镜像`starchat/synapse:v1.132.0-dedup.1`、sha256 a5e848c345b0f0731bd7f2e5151dee4cff6664f7577cc6e412a571daff9db776；loopback隔离实例。覆盖非默认ACL完整保持、转让后旧群主被拒、并列权限desync；实际写成功后丢回包人工确认不重复发送；文件SQLite关闭engine重开后全新协调器读取MATRIX_PENDING、权威确认并完成，仍仅一次实际写入。临时DB/容器已清理。PG探针与结果见[脚本](artifacts/2026-09-23/debug-feedback-transfer/postgres_group_probe.py)、[结果](artifacts/2026-09-23/debug-feedback-transfer/postgres.log)，独立测试容器已移除。完整verify由根任务统一执行，不重复启动。

## 启用复审要点与操作前提

1. 已有0087包含0075注册表与0080意图；发布前检查真实表/head及候选两文件SHA，并确认API/worker均取得`BUSINESS_GROUP_TRANSFER_COORDINATION_ENABLED=true`和既有Matrix配置。无需新迁移。不能只开API丢弃恢复worker。
2. 旧群首次发现的NULL不等同新建群，更不能直接填当前时间或30天前。满10人旧群可由管理员核验历史接任证据，通过既有`POST /admin/groups/{room_id}/owner-tenure`带真实UTC时间和reason_code补录，保留审计；证据不足仍拒绝，不能声称全部旧群立即可转。本任务未替用户补录生产数据。
3. API拒绝非成员首次登记，权威失败/并列最高权均不落行；原登记保持业务权威，不因客户端权限变更重置。并发首次登记可能返回安全503要求重试，最终只一条记录且NULL任期。协调并发单赢家、幂等重放锁序均有PG证据。
4. 发送后未知结果保留MATRIX_PENDING，不重复发送；恢复只读确认，不能确认转NEEDS_REVIEW。未决意图仍阻止新转让，人工复核只允许证实已应用或持久未发送证据，不能用旧群主快照当作未发送证据。
5. Matrix与SQL非原子事务，旧客户端直接改权限仍可形成desync；现有观测/复核处理这一残余，未声称所有外部改权竞态消除。默认开关仍false可回退停止新请求；回退时保留注册表和意图/审计，不破坏性downgrade。关闭worker会暂停恢复，先核对未决意图再决定恢复方案。

根任务需先独立规格审查再质量/安全复审，随后部署与生产读取验证；本报告不是已上线证明。持续计时：backend最终36.74秒、真实Synapse93.71秒、分析3.2秒；主动工作与等待具体分拆未知，未估算。
