# 点钻、手机号与群主规则：独立代码复审

## 范围与证据身份

用户授权：检查 ZCode 本轮修改、修正发现的问题、交付下一步 prompt。不包含生产发布、真实短信、真实资金、生产数据库修改。

- 审查对象：主工作区未提交的六项服务端修改，而非仅 Git HEAD。
- 基础提交：`3d9689971002bdab9dfa70eac63477308fb116b1`。
- 隔离分支：`codex/pricing-review-20260921`，工作树 `.worktrees/pricing-review`。
- 输入快照：主目录 `docs/verification/artifacts/2026-09-21/pricing-review/input-snapshot.json`，64 个修改/新增文件的 SHA256；22:18:20 +08:00 保存。
- 基线复现：以主目录原源码为 PYTHONPATH、运行隔离树新增回归测试，**26 failed / 1 passed，exit 1**。这些失败是测试断言数量，不代表 26 个独立业务缺陷。
- 环境：Windows / PowerShell 7 / Python 3.12.10；本地 PostgreSQL 16.9-alpine；无真实上游调用，汇率和短信使用替身。

## 已复现与修正

|级别|原问题|本轮修正|
|---|---|---|
|P1|错误验证码尝试次数随异常事务回滚，可超过 5 次猜测|失败计数提交后再抛业务错误；PostgreSQL 行锁保护消费/计数|
|P1|旧号码验证证明可被反复用于换绑，且窗口长于约定|当前联系方式绑定的 5 分钟证明，换绑成功原子作废；新验证码消费与换绑同事务|
|P1|手机号注册重试异常、缺少实际验证码接口、邮箱短信双通道混入|补齐实际注册/登录/换绑路由与端到端测试，二选一校验，兼容旧邮箱请求哈希|
|P1|仅手机号注册仍被 Matrix 开通的邮箱验证条件阻断；无邮箱的个人资料/客服目录报错|开通前及激活事务内验证真实手机或邮箱证明；保持 masked_email 字符串契约；真实 OTP→开通→ACTIVE→短信登录→HTTP 资料链路通过|
|P1|邮箱换绑验证码以明文进入 Outbox，worker 派生规则不匹配风险|Outbox 只存挑战 ID；同一派生器投递与核验，拒绝过期/联系方式已变的投递|
|P1|汇率首次失败无退避；慢请求可在另一请求完成后再次访问|失败缓存覆盖冷启动；原子认领同时检查有效期/退避；随机认领令牌防过期持有者写回|
|P1|full_backing 无新鲜汇率仍假设 1:1，与 ADR-0076 决策 6 冲突|有点钻负债时返回 RESERVE_VALUATION_UNAVAILABLE；有效报价低于 1 时仍按真实报价折算|
|P1|连续调价使用同一个冻结记账键，应付 30 而 HOLD 只有 20|每个调价操作独立幂等键；差额在用户 USDT 与 HOLD 间转移，余额不足拒绝；限制累计最终应付|
|P1|充值可用不存在/错误交易号标记完成，申请幂等键无效|验证已执行财务调整、用户、金额、分录与冲正状态；凭证一次消费；申请/决定持久幂等|
|P1|实际红包路由未注入群主服务，免手续费/抽成不生效|真实路由装配；创建事务锁定群主快照；旧群权威发现；补实际 API 金额测试|
|P1|已退出/被降权用户可登记或转让群主，接收人无需入群|登记验证唯一权威群主与 joined；领域转让验证双方状态/成员/权限；群主查询限制成员|
|P1|转让业务群主成功后仅要求客户端修改 Matrix，可能永久失配|**安全隔离：转让 API 暂回 503 GROUP_TRANSFER_UNAVAILABLE，不改群主/任期**；完整协调流程仍待实现|
|P2|点钻源金额先按 USDT 上限拦截，过期报价可冻结资金|按折算后 USDT 验门槛/上限；过期参考不用于创建资金义务|
|P2|极小汇率舍入成 0、无效 rate 偷用 result、指数溢出未退避|统一拒绝无效/溢出/金额方向错误响应；脱敏支持第一项 query 参数|
|P2|后台客服目录只有创建，没有修改/停用路由|增加按 ID 修改，缺失 ID 返回 404；保留管理员鉴权|
|P2|ADR 约定抽成回退开关缺失|补 BUSINESS_RED_PACKET_OWNER_COMMISSION_ENABLED，默认开启；只影响新红包抽成|
|P1|PostgreSQL 驱动 INSERT 行数返回值与 SQLite 不同，充值新请求误判为处理中|真实 PostgreSQL 复现后改为 INSERT RETURNING 判断认领；32 并发只生成一单|
|P2|汇率 HTTP 客户端 INFO 日志含带凭据 URL|在 httpx 源 logger 安装脱敏过滤器；MockTransport 日志回归确认 key/id 不泄漏|
|P2|在途应付报表仍汇总调价前的原金额|汇总 final_receive，空值才用原金额，避免应付 30 却报 10|

## 验证

- `baseline-red.log`：原源码上新增回归用例 26 失败 / 1 通过，exit 1。
- `focused-root.log`：修复中阶段 131 通过，exit 0；最终门禁结果见后续记录，不能用此阶段代替最终源码。
- `postgres-migration.log`：隔离空库实际执行 Alembic 0001→0078，exit 0。这是 online 迁移；`verify.ps1` 自身的 `upgrade --sql` 只是 SQL 生成，不等于生产迁移演练。
- `postgres-concurrency.log`：冷缓存 32 请求/16 连接只调用一次上游，过期后再 32 请求只增加一次；32 次并发短信请求仅发 3 条，32 次错误验证耗尽额度后正确验证码也拒绝。exit 0。
- `postgres-recharge.log` 保留驱动差异的失败记录；`postgres-recharge-fixed.log` 复测 32 请求仅创建一张申请，变更载荷重放拒绝，exit 0。
- 手机开通/资料补充：新增集成测试先出现 3 个预期失败；修正后与既有 provisioning/profile 回归合计 26 passed，exit 0（52.45s）。测试 Matrix 网关使用替身，未连接生产 homeserver。
- `verify-full.log` / `verify-exit.txt`：实际执行完整 `scripts/verify.ps1`；业务 API/worker 首轮 **2320 passed / 17 failed / 58 skipped，exit 1，1704.49s**。失败记录完整保留，**本轮不能写“最终完整 verify exit 0”**。
- 17 项失败逐项归因：15 项旧夹具缺少新储备规则所需的新鲜汇率（admin 1、充值修复 1、提现资金 7、钱包安全 6）；2 项支付 PIN 的红包网关替身缺少权威群主状态。仅补足前置条件，保留金额/资金/鉴权断言。旧 1:1 转换历史测试明确提供单位率，不能依赖缺报价时默认 1:1。
- `full-failures-fixed.log`：上述失败所属五个完整测试模块 **55 passed，exit 0**；另单独运行钱包操作路由发现 FxRate 建表依赖导入顺序，补显式模型注册后独立 **5 passed**，未改 409 安全断言。
- `verify-remaining.ps1` 是原 verify 脚本从移动边界步骤起的原样提取，独立补完首轮失败后未执行的门禁；`verify-remaining.log` **exit 0**：mobile 84 passed，UI contract 32 components / 375 screens，API import、249 文件 AST、单 Alembic head/离线 SQL、OpenAPI、Compose 通过。其中打印的 `Verification: PASS` 仅代表这个后半段，不能当作整个 verify 通过。
- 首轮前半段：infra 143 passed、Getui 28 passed、Matrix bot 9 passed，仓库/部署/模板/配置渲染门禁通过。原有依赖弃用警告（FastAPI/Starlette TestClient 与 Getui 生命周期）保留，不据此声称零警告。
- 58 个跳过项保留为未验证；包含需要 PostgreSQL 显式环境开关/测试连接的门禁。前述三项 PostgreSQL 实测不能覆盖这些跳过项，也不等价于真实环境全量验收。
- `final-changed-tests.log` / `final-changed-tests-exit.txt`：最终集中运行全部 21 个本轮新增/修改测试文件，加既有 `test_matrix_provisioning.py` 和 `test_profile_api.py`，**203 passed，exit 0，101.04s**，保留 1 条既有 TestClient 弃用警告。命令为 `py -3.12 -m pytest <integration-dry-run.json 中 tests/ 文件列表> tests/business_api/identity/test_matrix_provisioning.py tests/business_api/identity/test_profile_api.py -q --tb=short -ra`。
- 依据 mobile-delivery-workflow 的影响范围与证据复用规则，保留已运行全量结果，后续验证失败相关模块、新增与修改测试及晚期修改的认证/资料链路；没有第二次宣称全量绿色。
- 已安全回填主目录 **40 个代码/测试/契约文件**。`applied-changes.json` 保存每个文件前后 SHA256；`before-corrections/` 保存原文件；并发修改核对通过，无覆盖他人修改。`final-source.json` 冻结 614 个相关源码/配置/测试输入；主目录逐个比较有 346 个仅 CRLF/LF 差异，**实质内容差异 0**（见 `integration-source-comparison.json`）。主目录再运行 OpenAPI `--check`，exit 0；diff whitespace 检查通过。未提交 Git、未部署。

## 尚未完成，不能宣称生产就绪

已按认证、资金、群/红包三个边界进行独立规格审查，再做质量/安全复核；额外 PostgreSQL 复测发现并修正了 SQLite 未覆盖的 INSERT 结果判断问题。审查结论是本地修复可继续集成，**不是发布批准**。下列规格缺口仍保留，不以测试绿色消除。

1. 群主转让仍需要持久操作意图、Matrix 应用与观测、可恢复重试和一致性协调。HTTP 与数据库不能靠一个数据库事务变成原子操作。此次只阻断业务端点虚假成功，没有验证或阻止所有旧客户端直接修改 Matrix power levels 的路径。
2. 人工充值财务调整执行与案件登记仍是两个步骤。登记已核验真实凭证且不会二次入账，但“执行成功、案件未登记”的恢复与案件绑定需要下一批持久流程；后台不得重试新建财务调整来补登记。
3. 短信真实供应商、Flutter 页面、后台三页、双端真机和生产验证仍未完成。路由注入替身通过不代表真实短信通道已上线。
4. 未运行 500 人加密群聊压测；本轮金融/认证测试不能作为容量达标证据。
   PostgreSQL 专项只证明所列场景，不代表全部 PostgreSQL 门禁通过；完整测试的跳过项须按原条件单独列示。
5. 所有金额规则沿用用户确认：1 点钻=1 CNY、余额数字不变、外部 USDT、内部点钻、手续费 0.5%/群主 0.1%、无群钱包、满 10 人只影响本群群主免手续费及转让任期检查。

## 下一步

使用 `docs/workflow/prompts/2026-09-21-zcode-next-step.md`，先补后端一致性与发布前阻断项，再做管理端和 Flutter，不直接发布。
