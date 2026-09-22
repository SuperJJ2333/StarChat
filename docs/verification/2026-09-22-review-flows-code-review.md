# 第三轮待核对处置与隔离联测代码复审

日期：2026-09-22，Asia/Hong_Kong。用户授权检查 ZCode 第三轮修改并纠错；本轮仅本地实现与隔离测试，未部署、未发送真实短信、未处理真实资金、未修改生产数据。未改 Flutter 或其他任务的未提交修改。

## 结论与基线

原实现存在可复现的资金释放、群转让复核、后台实际接线及测试证据问题，不能据原摘要认定“全部剩余流程完成”。本轮修正如下，转让协调仍默认关闭。未新增数据库迁移，迁移头保持 0081。

- 隔离分支：`codex/review-flows-audit-20260922`；工作树 `.worktrees/review-flows-audit`。
- 从主工作区冻结 129 个相关未提交/未跟踪输入，源码 HEAD、准确快照时间及 SHA256 见 [input-snapshot.json](artifacts/2026-09-22/review-flows-audit/input-snapshot.json)。示例配置独立使用，没有复制生产 .env。
- 修正回填清单与前后 SHA256 见 [applied-changes.json](artifacts/2026-09-22/review-flows-audit/applied-changes.json)，回填前文件保存在同工件目录 before-corrections/。最终源码、工具与依赖身份见 [final-inputs.json](artifacts/2026-09-22/review-flows-audit/final-inputs.json)。

## 已确认并修复

| 级别 | 原问题与触发 | 修正 |
| --- | --- | --- |
| P1 | 充值调整缺失即允许释放；REJECTED 标签可以掩盖已有执行交易；可能释放已入账绑定后再次充值 | 根据持久账本及关联冲正核证。记录缺失/状态矛盾/丢失交易指针均保留待核对；complete_bound 的拒绝分支也统一处理 |
| P1 | 释放绑定→案件锁，与登记案件→绑定锁顺序相反；释放无独立幂等；旧页面操作可能作用于后来绑定 | 统一锁顺序；释放幂等/审计/Outbox；HTTP 必须提供 binding_id 与 Idempotency-Key，在案件锁内匹配绑定；旧请求重放不能释放新绑定 |
| P1 | 复核给 actor 拼 `recharge-review:` 前缀，正常 36 字符 UUID 会超过 PostgreSQL actor 字段且破坏身份 | 原样保留 actor；实际 PostgreSQL 验证 36 字符 UUID 可登记 |
| P1 | confirm_applied 直接 complete，但意图仍在 NEEDS_REVIEW/MATRIX_PENDING，始终无法确认完成 | 权威确认后持锁推进 MATRIX_APPLIED，记录复核 actor 并更新 token 隔离旧回调，再走正常 complete；重放和审计后崩溃恢复保持幂等 |
| P1 | fail_unapplied 仅凭旧群主当前持权释放，未排除迟到发送；FAILED 又被当作活动意图；迟到失败可复活终态 | 仅确定发送前失败的持久证据允许释放；不确定发送仍待核对；仅新安全 FAILED 可重新发起，旧不安全 FAILED 保持隔离；回调同时匹配 token 和阶段 |
| P1 | 管理复核绕过默认关闭开关，仍可改变转让意图 | ACTIVE + SYSTEM_ADMIN 校验后，同一协调开关控制所有复核写入 |
| P1 | 并列最高权限时 matrix_owner=None，owner_desync 反而 False；原联测的宽松 OR 断言没发现 | 读取成功但无唯一最高权标记 desync；读取失败显式 owner_authority_available=false，区分未知与一致 |
| P1 | worker 开启转让后注册不存在的 gateway.close，启动即 AttributeError | 增加拥有权明确、可重复调用的网关 close；只释放自身 HTTP client，不关闭外部注入 client |
| P2 | 待核对快照被案件空值覆盖；历史只看活动绑定导致 REGISTERED/FAILED 消失；游标边界检查不足 | 保留绑定最终金额/汇率；历史投影最近活动/终态绑定；created_at/id 稳定分页与严格游标校验；待核对队列可翻页 |
| P1/P2 | 页面调用的 review/history/timeline API 方法实际缺失，替身测试仍全绿；队列异常被显示成空；分页异步响应可倒序覆盖 | 补真实 AdminApi 方法与 HTTP 契约测试；失败明确提示；绑定级操作键、处理中按钮限制、写后刷新相关状态；分页请求防过期响应覆盖 |

规格符合性检查先对照用户既定计价、手续费、任期和人工结算规则，再检查状态机、权限、并发与审计。没有增加用户确认、客服调价审批或新的商业限制。充值与群转让由独立领域复审者复现修复，根任务核查变更与实际 PostgreSQL/Matrix 结果；根任务新增的权限开关、desync 与资源生命周期另经只读独立质量复审。受保护修正记入 ADR-0077/0079 第三轮补充。

## 原联测证据的修正

原 `test_real_synapse_second_intent_rejected_after_transfer` 只有 `assert True`，没有执行其名称声称的行为；原 ACL 检查只验证 events 的类型或缺省，未比较前后内容。因此旧的“2 passed”不能证明两项真实场景均完成。

现在两项真实测试分别验证：

1. 写入非默认 invite/redact/events_default/notifications/events ACL，完成转让后逐项比较整个 content；实际发起旧群主第二次转让并检查拒绝；再用旧客户端改成并列最高权，确认注册表不跟随且 desync=true。
2. 经真实网关发送权限事件，**在 Synapse 已接受后**注入返回丢失，确认阶段停在 MATRIX_PENDING；人工复核真实回读完成，重复复核仍只有一次发送。

本地 Synapse 仅绑定 127.0.0.1。运行目录位于本任务 artifacts，finally 删除本次容器与测试密钥目录；环境存在但启动失败会失败而非伪装 skip。Docker 不存在时不会在测试收集阶段 FileNotFoundError。专项设置 SYNAPSE_TEST_REQUIRED=1，缺少环境也不能跳过。

首轮加强断言暴露 desync 缺陷，同时测试夹具误调用 gateway.close、复用服务端触发登录频控；已分别修正资源拥有权和每个场景隔离实例，未降低限流。失败日志保留为 synapse-first-failed.log。

## 本轮验证

工件统一位于 [review-flows-audit/](artifacts/2026-09-22/review-flows-audit/)。工具：Windows / PowerShell 7、Python 3.12、Node、Playwright + Edge；精确版本与哈希见 final-inputs.json。没有真实资金、短信或生产服务访问。

| 检查 | 结果 | 日志/说明 |
| --- | --- | --- |
| 充值服务红/绿 | 初始 9 项失败后，充值全模块 44 passed（含 14 项新回归） | recharge-red.log、recharge-green.log |
| 群转让复核 | 初始 4 failed/1 passed；群模块 59 passed；最终受影响 21 passed | group-*.log；数量包含重叠，不相加 |
| API/权威可用性/实际 Synapse | 8 passed：真实 Synapse 2、desync 2、API 边界 4 | synapse-real.log / exit 0；初始 API header 断言误用 name 字段，已按真实 loc 契约修正，失败记录保留 |
| 网关生命周期 | 2 failed→2 passed | gateway-red.log、gateway-green.log |
| 前端 | 新断言首轮 4 failed；全量 235 passed / 0 failed | frontend-red.log、frontend-full.log |
| 浏览器真实 DOM + AdminApi | PASS：待核对、绑定级请求、重试/释放、历史分页、失败不冒充空，零页面异常 | admin-browser-result.json、admin-review-panel.png；使用本地 HTTP fixture，不冒充全后端联调或完整视觉验收 |
| PostgreSQL 16.9 实库并发 | 4 场景 PASS，exit 0 | postgres-review.log：16 路同键释放一条 audit/Outbox；旧回执不释放新绑定；登记持锁实际阻塞释放≥0.3秒，登记成功后释放安全拒绝；36 字符 actor 原样入库 |
| 完整 scripts/verify.ps1 | PASS，exit 0；后端 2440 passed / 58 skipped | verify-full.log、verify-exit.txt |

PostgreSQL 本轮使用唯一隔离 schema，不触及 public 或生产数据；容器已停止并自动删除。未改迁移、SMS SDK 或依赖锁，因此复用前轮同输入的 0001→0081 在线迁移和 Docker SDK 构建证据，本轮 PG metadata 建表不冒充重做迁移。完整门禁保留 skip 和已知弃用警告，不算已验收。

## 仍需后续处理

- 转让开关继续 false。任意外部改权、旧客户端治理、生产同版本网关及生产数据恢复演练仍不能从本地两项测试推断通过；旧版不安全 FAILED 不自动清理。
- 后台历史审计详情页与群转让人工处置工作台仍未完整实现；本轮修复既有入口，不把 API 存在当成 UI 全部完成。
- Flutter 尚未由本轮实现或验收；真实短信、双端真机、500 人压测均未执行。
- 新复核契约要求 binding_id/Idempotency-Key，未来客户端必须同步。请以此次 OpenAPI 与报告为准，勿回退到“缺记录可释放”“旧群主持权就证明没发送”或只靠替身的实现。
- 本轮无提交、无发布；回退先关闭相关写入口与恢复任务，保留所有账本/绑定/审计历史，不能通过删表或改状态掩盖资金事实。

后续执行可使用[下一批 prompt](../workflow/prompts/2026-09-22-zcode-after-third-review.md)，先补工作台，再独立推进 Flutter。
