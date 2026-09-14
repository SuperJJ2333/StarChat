# 窗口外充值人工补录验证

状态：本地实现与主线程验收完成；采用综合运行加失败项修正复测的组合证据。尚未生产发布或实际补款。

## 结果与边界

本次新增独立人工补录单，由历史有效地址绑定确定唯一用户。创建、批准或驳回、90秒预检、确认入账分为明确步骤；不能任意指定用户或改金额，不能复用普通订单。普通五分钟容差仍保持。

627.682362秒窗口外的合成交易已通过真实服务测试：订单通过原服务创建并在过期后处理；旧订单全部核对字段保持，收据关联人工补录单，用户充值记录可见，后台流水返回人工归属，账本只有一次平衡入账。生产两笔交易仅作为此前只读诊断背景，本轮未访问或修改生产财务状态。

Astra读取实际diff、服务、旧修复/提现重放、钱包历史/后台流水、ORM/迁移、API及前端调用链，发现并退回修复审批首次视图、重复请求、锁顺序、网络取证位置、最终事务复核和浏览器恢复问题。代码由显式指定 `gpt-5.6-terra` 的执行代理完成，主线程保持Astra，最多两个执行者同时运行。

## 主线程实跑证据

日志目录：[manual-deposit-cases](artifacts/2026-09-13/manual-deposit-cases/)。

| 命令/范围 | 结果 | 日志 |
| --- | --- | --- |
| `npm test`（frontend，最终候选） | 199通过，0失败 | astra-frontend-final-2.log |
| pytest：manual_deposit_cases + PG并发 + 新旧完整HTTP | 21通过 | astra-manual-and-http.log |
| pytest：新PG约束迁移 + 旧PG充值修复 | 7通过，无跳过 | astra-pg-migration-old-repair.log |
| pytest：严格确认参数 | 7通过 | astra-strict-confirmation.log |
| pytest：提交末端保护/审批/普通订单冲突 | 7通过 | astra-commit-guards.log |
| `scripts/export_openapi.py --check` | 通过 | astra-openapi-check.log |
| 综合门禁第二轮 | Infra143、Getui28、MatrixBot9通过；业务API/Worker1931通过、1失败、40跳过 | astra-verify-full-2.log |
| 旧0041→0051迁移测试修正后主线程复跑 | 2通过，无跳过 | astra-operations-migration-final.log |
| 综合门禁后续步骤 | 移动边界70通过；UI契约、导入、215文件AST、唯一head/离线迁移、OpenAPI、Compose通过，退出0 | astra-verify-remainder.log |

主线程在Chrome DevTools实际操作本地合成页面，走通创建→批准→预检→确认→`EXECUTED`，显示系统用户和账本编号。页面URL为 `http://127.0.0.1:4187/tests/manual-deposit-case-preview.html`；此页不连接生产。已实际查看基础样式修正后的截图，工具配置拒绝直接保存截图，因此没有声称已生成截图文件。浏览器结果不能替代后端和真机验证。

## 财务与权限断言

- 未审批/驳回、普通订单可用、历史用户错误、链证据异常不能入账。创建和执行的同键重放可在链节点不可用时恢复；跨类型命令和更换内容被拒绝。
- Decimal低全局精度场景仍保留USDT六位。公共账本服务负责余额写入，公共义务服务转移pending，未添加跨币转换或直接修改账本公式。
- 账本、收据、命令、审计、Outbox和义务在一个入账事务内完成。审计/Outbox异常、末端grant失效及flush后的时钟/证据/预检/储备失效均回滚。储备末端测试经主审纠正为第四次预算读取（已flush），避免只测试初始校验。
- 真实本机PostgreSQL18.3，独立UUID schema完整升级到0065，再实际执行0066。原生SQL验证已批准后的错用户/错收据拒绝、XOR归属、case/decision与已信用收据不可变；ORM同步回查批准与归属；普通intent路径兼容。并发case竞争只入账一次。
- 实际create_app与wallet grant验证无token401、非owner403、无grant403、确认参数422、开关关闭写503但结果可查、撤销grant后查询403。未降低既有审批、身份和钱包验证边界。

## 失败记录与环境

首轮综合门禁在Infra阶段3失败/138通过，原因是0066预检新增表，而旧fixture未导入repair_models。只修正测试结构与缺表断言，未放宽生产预检；保留astra-verify-full.log和首轮退出码。早期审批同键测试的首次返回仍待审批也由主线程复现，修复后通过。

执行者的 `.venv` 缺ruff，未称ruff通过。综合门禁使用既有全局Python3.12.10；其Getui测试显示Starlette/httpx与Pydantic旧Config的两项依赖弃用警告，未隐藏，当前未因本次改造更换这些无关依赖。40项跳过属于其他可选集成环境/运行开关（如RUN_POSTGRES_TESTS及专用鉴权、PIN、绑定数据库配置，以及SQLite模式的跨进程测试）；本功能真实PG测试已执行，不能把这40项算作通过。

本任务未改Flutter。比对前轮760个Dart文件发现6项外部并行改动，pubspec.lock不变；详见flutter-evidence-reuse.json。此前2508通过仅属于前轮候选，不能称当前整个工作区Flutter全量通过。未覆盖这些改动，真机验证由用户负责。

变更审查净diff：[task-only-review.diff](artifacts/2026-09-13/manual-deposit-cases/task-only-review.diff)，从任务开始时的脏工作区补丁重建，区分本轮新增和此前客服/钱包修改；最终hash位于final-input-sha256.json。综合验证输入变化另行检查。未clone/pull/reset/commit。

## 使用与发布

操作见[人工补录手册](../runbooks/manual-deposit-cases.md)。发布前需按管理后台工作流应用迁移与前后端候选；停止写入时保留查询与全部财务历史，禁止破坏性降级。源码本地验证不代表线上两笔交易已恢复。

第二轮唯一失败为旧0041迁移测试直接比对已包含0051字段的当前ORM。修正为先验证0041历史结构，再实际执行0051并验证当前模型，同时保留账本金额和标记不变断言；Astra亲读diff并复跑2通过。两轮原始verify.ps1退出1均保留，不声称整条脚本曾退出0。依据未变输入证据复用1931项成功结果，单独复测失败项并跑完余下门禁；后端生产源码在综合运行期间保持不变，唯一前端变化另有最终199项通过证据。详见verify-input-stability.json。

收尾：隔离PostgreSQL已确认停止。自动审批审查拒绝后续包含递归清理pg-data与停止预览进程的命令（blocked by policy）；命令未执行，合成pg-data和日志保留，本地4187预览可能仍运行。未尝试绕过该限制。

后续状态：2026-09-13用户另行授权后已部署生产（API119e6971/schema0066）；以上未部署描述为本地验收时的历史状态。见[生产发布证据](2026-09-13-manual-deposit-production.md)。未实际补款。
