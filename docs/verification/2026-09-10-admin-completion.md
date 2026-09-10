# 管理后台五模块交付与验收 — 2026-09-10

本记录描述本轮实际实现及验证结果；[最初规格](../superpowers/specs/2026-09-10-admin-wallet-v2-design.md)保留为历史方案和排查证据，其中拟定字段、接口和额外能力不自动视为已交付。执行依据为[已授权计划](../superpowers/plans/2026-09-10-admin-completion.md)。生产真实资金补录仍需官方钱包管理员核对准确订单、付款证据并明确确认，本轮没有替管理员执行该笔补入账。

## 1. 点钻流水（L1、L2、L3）

实际入口为 `GET /api/v1/admin/ledger-entries`，不是草案中的 `/ledger/entries`。服务端沿用 `audit.view` 查询权限及后台会话边界，返回 `Cache-Control: no-store`，记录 `admin.ledger.viewed / ADMIN_LEDGER_VIEW` 审计；不记录原始查询邮箱。实现见 `app/modules/admin/ledger_entries.py`、`app/api/admin.py` 和 `frontend/src/admin-ledger-panel.js`。

| 实际字段/行为 | 实现口径 |
| --- | --- |
| 行粒度 | CAIBI 账本分录，`entry_id`、`transaction_id`、`account_id`；不把两条对手分录当两次发行 |
| 用户 | `user_id`、`username`（畅聊号）、`nickname`（用户名）分列；邮箱仅作筛选 |
| 账户类型 | `account_kind=USER/PLATFORM/ESCROW/UNKNOWN`；托管与平台账户有独立文字标识 |
| 时间/金额 | `created_at` 返回 UTC，界面北京时间；`amount` 为两位小数字符串，保持正负记账含义 |
| 场景 | `scene=GROUP/EXCLUSIVE/DIRECT/TRANSFER/OTHER/UNKNOWN` |
| 分配方式 | `mode=RANDOM/EQUAL/EXCLUSIVE/OTHER`，与场景独立筛选和组合展示 |
| 原因 | 保留 `reason_code`、映射 `reason_text`；未知原因标 `MISSING_REASON`，场景证据不足标 `SCENE_UNVERIFIED`，多业务关联标 `AMBIGUOUS_BUSINESS_LINK` |
| 查询 | `username/nickname/email/start_at/end_at/scene/mode` AND 组合；文本模糊匹配转义通配符，结束时间为排他上界 |
| 分页 | 前端每页25；API允许1–100；返回 `items/total/next_cursor`，固定时间与ID倒序，游标绑定筛选摘要与查询截止时间 |

中文原因覆盖红包创建/领取/到期退回、聊天转账创建/接收/到期/拒收、客服发放/调整、发行/回收/冲正等已知代码。没有可靠业务快照的历史 `room_id` 不能证明群聊；实际读模型返回 `UNKNOWN`，不会为了填满 GROUP 分类猜造历史信息。GROUP 枚举存在不等于已有可信 GROUP 历史投影。

查询成功才提交筛选、页码和游标；失败保留上次结果与已确认分页状态，重置清空条件并回第一页。已验证分页失败与筛选失败恢复。**跨后台模块离开再返回后的状态恢复未验证，且本次没有新增账本凭证详情接口或详情页。**

## 2. USDT提现与支付验证（A1）

名称统一为“USDT提现与支付”，保留此前已上线的后台48小时、钱包固定60分钟策略。钱包期限取验证时间加60分钟与后台会话截止时间较早者，状态读取不续期。接口为 `GET /api/v1/wallet/manual/access`、`POST .../verify`、`POST .../revoke`；服务端凭证绑定管理员、设备、会话 family、凭据及配置版本。权限和会话变化会撤销使用资格，资金提交前再次核验。

未知/到期/撤销态清除敏感内容和挂到 document.body 的链上、事故、修复详情弹窗，再显示原生验证模态、背景 inert 与遮蔽。密码/TOTP 不存浏览器。已知截止时间即时隐藏；远端撤销在下一次请求拒绝，界面通过30秒只读轮询、焦点/可见性及跨标签通知发现，未实现服务器推送。

“刷新当前操作状态”不提交资金命令。修复恢复记录按账号、命令种类与链事件隔离，仅保存 operation_id；未知结果只查询。服务端404后允许明确重新预检并保留原 operation_id，再次业务确认；不会生成新键自动重放。提现核对 `SUBMITTED` 表示候选已受理，保留恢复记录，不误称已结算。继承验证证据见[钱包生产记录](2026-09-10-wallet-access-production.md)及[前端记录](2026-09-10-wallet-access-frontend.md)。

## 3. 链上置顶、详情、事故与视觉（C1、I1、V1）

钱包页先显示官方链上流水，再显示钱包操作、监控与事故。链上实际接口为 `/api/v1/admin/wallet/chain/summary`、`/transactions`、`/transactions/{txid}/{log_index}`，完整前缀均为 `/api/v1/admin/wallet/chain`。保留原 `direction/start_ms/end_ms/txid/limit/offset/snapshot` 查询，失败不推进已确认 offset 或替换筛选快照。

详情使用原生 dialog：交易哈希/日志索引、区块、来源/目标地址、精确金额、关联收款/提现单、用户、账本交易、意图、原因和证据状态。新增用户安全字段 `user_username/user_nickname`；充值归属投影为 `LINKED/BOUND_ORDER_UNMATCHED/UNBOUND` 及中文解释。发现历史地址绑定只说明存在绑定记录，不证明本笔属于某用户；未匹配订单不能自动入账。`VERIFIED/UNVERIFIED/CONFLICT` 是证据状态，与 `CREDITED/REVIEW/SETTLED` 记账状态分开。

事故接口为 `GET /api/v1/admin/wallet/incidents` 和 `.../incidents/{id}`。API支持 `status[]`（OPEN/ACKNOWLEDGED/RESOLVED）、`severity[]`（P0/P1）、`code[]`、`condition_active`、`sort`（opened_desc/opened_asc/updated_desc）、limit/cursor；界面提供状态、等级、代码及排序单项选择和每页25条。返回 items、next_cursor、total、snapshot；签名游标绑定筛选、数据版本快照及10分钟有效期，变化时明确拒绝旧页。

事故详情呈现原因、影响范围、时间线、版本和明确关联记录。关联种类为 WITHDRAWAL/DEPOSIT_RECEIPT/MANUAL_PAYOUT/USER，仅使用持久明确关联并核实对象存在，不按时间相近猜测。时间线最多200条，API有 `timeline_has_more`；当前界面尚未呈现截断提示。处理事故仍不恢复资金，资金恢复是另一项显式确认操作。

链上与事故详情关闭保留列表DOM、筛选与分页，恢复仍存在的触发按钮焦点；销毁页面会关闭弹窗并忽略迟到响应。表格容器滚动、筛选换行、模态限高和小屏样式已实现。真实浏览器预览覆盖链上详情、事故模态、钱包修复交互与关闭恢复；证据为 `artifacts/2026-09-10/admin-completion/browser-result.html`、`chain-modal.png`、`incident-modal.png`、`ledger.png`、`wallet.png`。小屏截图 `wallet-small.png` 已存在，最终小屏尺寸/溢出验收由主任务补充，不能仅凭文件存在判定通过。

## 4. 转入补入账与转出核对（F1、F2）

| 流程 | 实际接口 |
| --- | --- |
| 转入候选 | `GET /api/v1/admin/wallet/manual/deposit-repairs/candidates?txid=...&log_index=...&query=...` |
| 转入预检/提交/查询 | `POST /api/v1/admin/wallet/manual/deposit-repairs/preview`、`POST /api/v1/admin/wallet/manual/deposit-repairs`、`GET /api/v1/admin/wallet/manual/deposit-repairs/{operation_id}` |
| 转出预检/提交/查询 | `POST /api/v1/admin/wallet/manual/payout-reconciliations/preview`、`POST /api/v1/admin/wallet/manual/payout-reconciliations`、`GET /api/v1/admin/wallet/manual/payout-reconciliations/{operation_id}` |

INFLOW 打开充值补入账；转出打开提现核对。按钮入口不代替服务端资格检查，已有入账、错误方向、状态或证据冲突由预检/执行拒绝。候选按来源地址检索，支持精确订单号、畅聊号、昵称或金额，最多100条并提示缩小范围；展示候选状态，选择不等于通过资格核验。预检展示订单/用户/金额/地址/绑定区间/时间/状态等快照，90秒有效，返回 preview_id、digest、expected_version、confirmation、blockers。阻断原因中文展示。

原因枚举为 `CLOCK_ORDERING_REVIEW/EXPIRED_INTENT_REVIEW/ATTRIBUTION_CORRECTION/PAYMENT_BEFORE_ORDER/OTHER`，说明1–500字。先付款后建单必须选择 PAYMENT_BEFORE_ORDER、明确 payment_attestation，且差值最多300秒；全部正常和前移窗口中的同额同来源候选参与歧义判断。不会将当前时钟偏差直接减到历史时间。其他条件仍需网络、完整固化证据、金额、绑定、控制、储备、用户和可信时钟全部通过。

执行要求 `confirmed=true`、版本/摘要、operation_id 和 Idempotency-Key。只允许现有官方钱包 owner、有效后台会话和 wallet grant，不向 finance.review/audit.view 追加修复写权限；没有新增第二业务审批人或草案细粒度审批角色。详见[ADR 0066](../adr/0066-manual-deposit-repair.md)。

充值通过现有 WalletLedger 和义务转换公共接口，同事务提交平衡USDT分录、待处理义务转信用、不可变命令、审计和Outbox。原 EXPIRED 状态/历史时间与原收据原因保留。迁移 `0064_admin_deposit_repairs` 为扩展表、唯一约束及原生 UPDATE/DELETE 拒绝触发器。提现仅向已 CLAIMED/UNKNOWN 且属该 owner 的订单提交候选，复用原 reconciler 结算，不签名、不广播、不发起转账，不用转出给用户充值。

资金测试的 red/green、157项相关测试及后续负例、独立领域/质量安全审查、真实PG3项并发/不可变约束验证见[资金验证](artifacts/2026-09-10/admin-financial-completion/verification.md)。覆盖同键重放、竞争键只一次信用、晚期授权/审计失败回滚、时钟/预检/证据过期、守恒和平衡。CLI 已交付 `scripts/admin_deposit_repair.py`，默认无请求；candidates/preview/status/execute 调用真实受保护 API，执行要求 --confirm 与稳定 operation_id。令牌仅环境变量、TLS 校验、未知结果仅查询。CLI 与完整挂载应用/迁移合并23项通过，证据见资金工件 cli-integration-tests.txt；未执行生产资金修复。

## 5. 指定哈希根因、影响与修复边界（X1）

历史只读证据见[规格§5](../superpowers/specs/2026-09-10-admin-wallet-v2-design.md#5-指定交易的实际排查结果)：`ab0ddd6a2723884b6ffe323ad4260aa1e25d61ecd398d5b20d35aee225a74c09 / 0` 是10.000000 USDT转入，固化区块86119339，链上北京时间16:46:51。当前订单记录创建晚30.682362秒，因此 `created_at ≤ block_time` 不成立；收据 `5bcd3d76-cfc4-4dd8-b3c1-d800f16b800a` 为 REVIEW/NO_UNIQUE_INTENT，保留待处理义务，用户/订单/账本关联为空。v2绑定区间覆盖本事件，v1已重绑关闭，不能用旧单替代。

这是“有绑定但无通过匹配的订单”，不是漏扫。普通 retry_credit 不重新归属 NO_UNIQUE_INTENT，重新扫描或校时不会自动修复旧收据。原排查窗口没有匹配ERROR/Traceback；轮询持久记录和审计已有处理证据，不能声称回调丢失。原排查全库有2条此原因的REVIEW，本笔已核实，另一条不能推定同一根因；当时未发现本笔重复入账或证据冲突，不能扩展成全钱包无异常结论。

当时主机未同步，HTTPS时间参考显示约快59–60秒；没有事发时精确可信对时记录，故时钟偏差是高度相关的上游疑因，不能据此证明历史真实顺序。后续只读时钟排查见[时钟证据](artifacts/2026-09-10/admin-clock/README.md)。校时发布由独立 ADR 0067 与维护任务记录，不以本报告替代其最终同步结果。

本次新增已覆盖30/300秒人工先付款例外、301秒/无明确证明拒绝、原事实保留、可信时钟拒绝等回归；不宣称最初草案列出的每一个“+59秒自动路径”复现都已单独实现。既有只读修复预检为 writes=0；上线受保护公共API后，管理员须核实准确订单和原始证据，重新预检、明确确认，再查最终账本结果。不得SQL改余额、改订单时间或伪造历史归属。

## 6. 发布、验收和回退（W1、D1）

默认跳板访问、验证证据存放、最小生产覆盖、备份恢复和回退规则已固化到 AGENTS.md、`scripts/starchat-server.ps1` 与[后台生产工作流](../runbooks/admin-production-workflow.md)。

主任务确认已上线 API 镜像 `sha256:84edda0271dae31b71a74f0d3c1fbff3112bcd4e263c6f3e859767b6d2e3c5d8`、schema `0064_admin_deposit_repairs` 及10个后台静态文件；隔离恢复演练 PASS，无关容器保持不变。发布清单/来源差异/恢复与切换脚本保存在 `artifacts/2026-09-10/admin-completion/production/`；详细脱敏生产验收结果由主任务汇总，敏感数据库备份和配置仅留服务器受限目录。

完整 `scripts/verify.ps1` 最终 PASS：API/Worker 1792 passed、49 skipped（830.46秒），infra140、Getui28、Matrix Bot9、Flutter边界70通过；UI契约22组件/332页面、211文件AST、导入、迁移、OpenAPI与Compose检查通过，见[完整日志](artifacts/2026-09-10/admin-completion/full-verify.txt)。保留日志中的既有依赖弃用警告；49项skip不算已执行成功，PG金融验证另有真实隔离证据。主任务确认最终前端151项及真实浏览器验收通过；本次独立QS另跑五个前端专题共72项，全部通过，无skip。

规格/领域先审，资金和根接口质量安全后审，阻断均修复复审通过。根接口QS无阻断；事故时间线截断提示为非阻断观察项。本文只新增/修改文档，不改变已评审代码。

回退先关闭 `wallet_manual_repairs_enabled` 停止新命令，保留预检和结果查询；恢复发布前冻结的API镜像/配置及静态文件。新增案件表、账本、审计与Outbox保留，不破坏性downgrade，不用旧数据库快照抹去成功入账。已成功资金纠错必须另行批准追加关联冲正/补偿。钱包grant及独立校时按各自运行手册回退，不无意改变48小时后台策略。

## 7. 草案额外能力与证据限制

未交付为既成能力：账本凭证详情、独立业务动作/多选原因/异常开关、页大小选择、默认7天/90天限制、导出、经审计原因补注、跨模块导航状态恢复、真实容量P95/EXPLAIN指标；事故时间/用户/交易复杂筛选、全部草案关联字段和审计跳转；第二资金审批人和细粒度新权限；新金融查询独立灰度开关。事故列表已有的筛选、分页、详情和资金保护按上述实际范围验收，不把草案所有增强项笼统计入“全部完成”。生产已发布实现不等于指定资金已入账。最终补证见下一节。


## 8. 最终生产与浏览器补证

2026-09-10 最终 static_release.py verify PASS：API healthy、restart_count=0，10个静态文件哈希一致，下载/首页/admin-session.js及无关容器未变。恢复、候选、迁移证明与实际镜像绑定，见 artifacts/2026-09-10/admin-completion/production/final-verification.txt。候选证明中的旧字段名 identical_except_approved_worker_budget 是复用脚本的历史标签，本次实际允许差异为 API 镜像与 BUSINESS_WALLET_MANUAL_REPAIRS_ENABLED，Worker未变。

服务器 ledger/repair candidates/incidents 未登录均401、Cache-Control:no-store；API容器 ClockHealth=True，两个独立TLS参考的主机偏差约1秒以内，连续5分钟采样未再出现启动瞬时重复。证据 security-clock-postflight.txt。chrony manual 的 Not synchronised 不等于 NTP同步成功，健康依据是独立参考探测。

工作站通过已有jumper的loopback SOCKS、保留TLS验证：readiness JSON ok=true；后台admin.html SHA256=5428697030606a0977f6e051fddaa2dacc3426644db9b3b69728885a6aaba4c1，与发布源一致。一次连接关闭后单次重试通过，没有关闭证书校验。

真实Chrome设备模拟390px：document.scrollWidth=390，两业务卡片宽358/right374，宽表格在自身容器内滚动；见 small-screen.json、wallet-small.png。合成预览测试头部另做换行，非生产样式变更。事故时间线最多200条时提示已补。CLI最终合并23项通过；实际提现结果展示 payout_status/review_reason。

本次未持有生产管理员验证会话，生产验收限健康、部署一致性及未授权拒绝；成功写入、撤销、重放与并发在隔离真实PostgreSQL和完整应用接口验证，未伪造生产会话。

主工作区集成后复验：OpenAPI check PASS；账本/CLI/完整挂载应用/迁移/发布基线/时钟专项68 passed（24.97s），前端补全与钱包验证10项通过。保留既有Alembic path_separator弃用警告。临时金融PG容器、独立网络/卷、工作站公网隧道已清理；生产业务容器未参与清理。
