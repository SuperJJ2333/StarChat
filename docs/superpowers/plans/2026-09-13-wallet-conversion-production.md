# 充值自动兑换与历史补兑换执行计划

授权：用户已要求线上兑换功能、两笔历史已入账账单兑换给用户，并确认新充值自动转点钻。主线程 Astra 审查，显式 gpt-5.6-terra 执行；当前工作区不克隆/拉取/覆盖改动。关联 ADR0070、0010、0056；最初核查时间 2026-09-13 14:11 +08。

- [x] C1 领域复核/基线：conversion_audit 只读核对现有兑换、APP入口、门禁并运行针对测试。Astra 核对生产两收据、开关、镜像和调用链，批准 ADR0070 的实施边界。35个既有兑换专项通过（先补齐测试进程模型注册），接纳保留键命名空间与真实actor意见，开始C2。
- [x] C2 自动兑换：执行代理独占 wallet/conversions.py、新 deposit_conversion.py（如需要）、receipts.py、repairs.py、manual_deposit_cases.py、runtime.py、core/config.py 以及专门新增 tests/business_api/wallet/test_deposit_auto_conversion.py 和必要配置测试。禁止修改 ledger 核心及 payout/model，除非主审明确追加。默认关闭开关，三路径共用方法与原事务；精度、余额、授权、暂停、reserve、actor/audit/outbox、固定收据幂等。先 red 后 green，三路径/回滚/重放/金额尾数/历史两笔/用户不符/并发 PG 验收。
- [x] C3 契约与操作可见性：在 C2 冻结接口后串行维护响应、必要前端确认文案/结果和 OpenAPI；已存在用户双向兑换 UI 不重做。复核现有用户兑换入口与点钻账本原因映射，无新增界面，不重复制作已交付 demo；新增操作说明 docs/runbooks/deposit-auto-conversion.md。明确文件所有权后才修改。保留所有原 API 字段及旧客户端兼容。
- [x] C4 主审与回归：Astra 实际 diff、调用链、规格合规再安全质量复核；针对测试、真实 PG 并发/原子性、适用 verify 门禁、前端回归与 UI 契约。其他任务未发布变更不得进入候选。
- [x] C5 生产与历史执行：Terra 在本任务 artifacts 独占准备最小发布/恢复/精确两收据补兑换工具，Astra 亲审后执行。当前 API 镜像重新读取（首次为 dc41eb54，已非119e6971），worker初读7e0e9ffc；服务器私有备份、隔离恢复、候选测试、静态/API hash和401健康。历史兑换先输出用户/金额/余额/键证据，再同事务兑换10+10并读取点钻/USDT实际分录、审计、Outbox、结果及重复执行不增发证据。

所有生产写入须在 C4 通过后，禁止直接SQL改余额/旧账本或伪造登录/验证凭据。当前两收据均归同一用户，USDT可用20.000000，CAIBI11.97（14:13只读快照，执行前重读，不能作为不变事实）。新充值自动兑换失败必须保留可重试事实/待处理状态，不能丢收据。



