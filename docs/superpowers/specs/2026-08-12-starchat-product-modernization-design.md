# StarChat 产品化改造设计规格

**状态：** 已批准  
**日期：** 2026-08-12  
**适用仓库：** `StarChat`  
**目标基线：** 10 万注册用户、1 万日活、2,000 同时在线、500 人群组、每日 10 万笔积分/红包交易、账本峰值 50 TPS、单区域部署

## 1. 目标

将当前 Matrix Synapse、Element Web 与 FastAPI Bot 集成骨架改造为完整的 StarChat 产品，交付：

1. 用户名、密码、邀请码与强制邮箱验证注册，不要求实名和手机号。
2. 由后台授予并可验证的官方客服身份。
3. Android/iOS Flutter 客户端和 React/TypeScript 管理后台。
4. 私聊、群聊、复制粘贴、已读、撤回、图片、文件、语音消息和端到端加密语音/视频通话。
5. 不可修改的复式积分账本、客服上下分审批、用户积分互转与 0.5% 手续费。
6. 群聊/私聊的等额与拼手气积分红包。
7. 通过第三方托管服务提供 USDT-TRC20 充值与提现。
8. 可审计的权限、审批、幂等、对账、发布和 Agent 协作体系。

## 2. 明确不做

- 不做实名和手机号注册。
- 不允许积分兑换 USDT，也不提供 USDT 用户互转或 USDT 红包。
- 平台不读取、搜索、扫描或风控普通聊天正文和附件。
- 平台不保存用户 E2EE 恢复密钥、房间会话密钥或明文附件。
- 首版不提供群组语音/视频通话；群组加密通话属于第二阶段。
- 平台不自行保存链上私钥，不自建热/冷钱包签名系统。
- Android 不上 Google Play；提供受控 APK。iOS 通过 TestFlight 分发。

## 3. 总体方案

采用“Matrix 通信域 + 模块化业务后端”的单仓库架构：

- **通信域：** Synapse 负责设备、房间、密文事件与密文媒体；客户端负责加解密。
- **通话域：** Matrix 信令配合 WebRTC、TURN/SFU；媒体在设备端加密，中继只转发密文。
- **业务域：** FastAPI 模块化单体负责账号、客服、积分、红包、钱包、审批与审计。
- **客户端：** Flutter 同时交付 Android/iOS。
- **管理端：** React + TypeScript 独立后台。
- **异步任务：** Worker 处理邮件、过期红包、托管查询、对账、Outbox 和推送。
- **数据：** Matrix PostgreSQL 与业务 PostgreSQL 分离；Redis 只用于缓存、限流、短期锁和任务协调，不作为资金事实来源。

### 3.1 信任边界

1. 资金状态不能由 Matrix 消息、Bot 回调或客户端显示结果决定。
2. 红包和转账卡片只是 E2EE 展示载体；真实状态必须从业务 API 查询。
3. 官方客服标识必须由业务 API 返回，不能由 Matrix 昵称或头像证明。
4. Matrix、媒体存储、TURN/SFU 和推送服务不得获得明文内容。
5. 托管商密钥只能存在于 Secret Manager 和 Wallet 适配器运行环境。
6. 报警、日志和追踪不得记录密码、Token、恢复密钥、消息正文、完整钱包地址或托管密钥。

## 4. 项目结构

```text
.
├── AGENTS.md
├── apps
│   ├── mobile_flutter
│   └── admin_web
├── services
│   ├── business-api
│   │   └── app/modules
│   │       ├── identity
│   │       ├── support
│   │       ├── ledger
│   │       ├── redpacket
│   │       ├── wallet
│   │       ├── audit
│   │       ├── notification
│   │       └── integrations
│   ├── business-worker
│   └── notification-bot
├── packages
│   ├── api-contracts
│   └── event-schemas
├── infra
│   ├── synapse
│   ├── turn
│   ├── proxy
│   ├── compose
│   └── production
├── scripts
├── tests
└── docs
    ├── adr
    ├── runbooks
    └── superpowers
```

模块只能通过公开 application 接口协作，禁止跨模块直接写表。Ledger 与 Redpacket 位于同一业务数据库，以便原子提交账本和红包状态。

## 5. 技术规范

- Backend：Python 3.12、FastAPI、SQLAlchemy 2、Alembic、PostgreSQL 16、Redis 7。
- Mobile：Flutter/Dart、Matrix SDK、WebRTC、SQLite 本地密文缓存、系统安全存储。
- Admin：React、TypeScript、Vite，使用 OpenAPI 生成客户端。
- API：REST `/api/v1`，OpenAPI 是客户端契约来源。
- 异步一致性：PostgreSQL Transactional Outbox；资金事务提交后才允许异步通知。
- 金额：数据库 `NUMERIC`，应用层 `Decimal`；禁止 `float`。
- 容器和依赖：锁定版本或镜像 digest；生产禁止 `latest`。
- 开发：Docker Compose；生产配置、密钥和数据与源码分离。

## 6. 身份、注册与恢复

### 6.1 注册流程

1. 校验管理员生成的邀请码，包括有效期、剩余次数和允许用户类型。
2. 接收唯一用户名、唯一邮箱和密码。
3. 发送一次性邮箱验证码并执行速率限制。
4. 验证成功后，在一个业务事务中创建用户、零余额 POINT/USDT 账户和 Matrix 映射记录。
5. 通过受限的 Synapse 管理集成创建 Matrix 用户。
6. Flutter 首次登录生成设备密钥、交叉签名材料和独立恢复密钥。

用户名注册后不可修改。邮箱可以作为登录名和密码找回入口；修改邮箱必须验证旧邮箱，旧邮箱不可用时进入人工审核。邮箱只有本人和授权管理员可见。

业务账号采用 `PENDING_EMAIL -> PENDING_MATRIX -> ACTIVE` 状态机。业务数据库与 Synapse 不能组成单一数据库事务，因此创建 Matrix 用户使用稳定 localpart 和幂等编排：Synapse 创建成功后才激活业务账号；超时只查询或重试同一 localpart，不创建第二个用户。处于中间状态的账号不能登录或进行资金操作。

### 6.2 邀请码

- 仅管理员创建。
- 支持批量生成、有效期、最大使用次数和用户类型。
- 可选记录创建者和推荐人，但不形成默认层级返佣关系。
- 注册消耗邀请码必须与用户创建原子提交。

### 6.3 密钥恢复

- 邮箱找回只恢复登录权，并撤销旧业务会话；不能解密历史聊天。
- 密码找回或无旧设备的新设备恢复成功后，提现默认冷却24小时；财务可以在完成加强复核后提前解除。
- 优先通过已验证设备扫码确认新设备。
- 没有旧设备时，用户输入独立恢复密钥，下载并在设备本地解密 Matrix 密钥备份。
- 服务端只保存加密后的密钥备份，不保存恢复密钥。
- 用户丢失全部验证设备和恢复密钥后，仍可恢复业务账号和资金，但历史聊天永久不可恢复。

## 7. 官方客服

### 7.1 角色

- 普通客服
- 财务客服
- 客服主管
- 超级管理员

后台管理员授予或撤销角色。角色变更后立即撤销受影响的业务 Token，并更新房间加入权限。

### 7.2 官方标识

业务 API 返回官方状态、客服编号、角色、特殊颜色和官方说明。Flutter 必须使用该可信响应渲染徽章；Matrix 昵称、头像和自定义资料不能独立产生官方标识。

### 7.3 排队和转接

1. 用户按业务类型创建客服工单，业务记录不包含聊天正文。
2. 按在线状态、技能标签和当前会话数最少的顺序自动分配。
3. 用户客户端创建 E2EE 客服房间并邀请已认证客服。
4. 客服可以转接，主管可以强制转接。
5. 新客服获得当前工单历史密钥，用户收到明确转接通知。
6. 旧客服被移除并轮换后续会话密钥；其已解密过的历史无法远程收回。
7. 客服离线时未关闭工单回到队列；关闭后允许用户重新发起。

一个用户可以同时拥有多个不同业务类型的客服工单。系统记录响应时长、转接次数、关闭原因和满意度，但不记录消息正文。

## 8. E2EE 聊天、附件和通话

### 8.1 消息

- 私聊、群聊、客服房间和系统通知房间默认并强制 E2EE。
- 支持文字、复制粘贴、回复、已读、撤回、图片、文件和语音消息。
- 附件上传前在设备端加密，对象存储只保存密文。
- 服务端不提供明文全文搜索、敏感词扫描、附件预览或病毒扫描。
- 撤回使用 Matrix redaction，不能保证删除对方已经读取、截图或另存的内容。

### 8.2 举报和封禁

- 举报者主动选择消息，由客户端在本地解密并提交证据副本。
- 平台只能查看用户明确提交的证据。
- 举报材料使用独立存储、静态加密、严格 RBAC 和访问审计。
- 封禁作用于业务登录、Matrix 账号和房间成员资格。

### 8.3 通话

- 首版支持一对一端到端加密语音和视频通话。
- 信令事件通过 E2EE Matrix 房间交换。
- WebRTC 媒体在设备端加密，TURN/SFU 只中继密文。
- 平台不录音、不录像。
- 平台可以保留呼叫双方、时间、时长和结果等元数据。
- 群组加密通话在第二阶段实现。

### 8.4 推送和 Bot

- APNs/FCM 推送只包含通用新消息提示，不含正文、金额和附件信息。
- 现有 Bot 不得加入普通私聊和群聊。
- 通知 Bot 只能加入专用系统通知房间，仅生成平台自身的通知内容。

## 9. 复式账本

### 9.1 不变量

- 账本交易和分录只追加，不更新、不删除。
- 每个交易内、每个资产代码的分录总和必须为零。
- 用户可用余额不得为负。
- POINT 精度为2位，USDT 精度为6位。
- 不允许跨资产平衡，不允许 POINT/USDT 兑换。
- 纠错只能创建关联原交易的反向冲正交易。

### 9.2 账户类型

- 用户可用积分
- 用户冻结积分
- 红包托管积分
- 平台积分发行/回收
- 平台积分手续费收入
- 受控系统调整账户
- 用户可用 USDT
- 用户冻结 USDT
- 托管资产/在途/费用账户

### 9.3 积分转账手续费

```text
fee = max(0.01, ROUND_HALF_UP(amount × 0.005, 2))
sender_debit = amount + fee
receiver_credit = amount
platform_fee_credit = fee
```

转出方额外承担手续费，接收方获得完整金额，手续费进入平台手续费账户。转账在单个数据库事务中锁定相关账户、校验余额、创建平衡分录和 Outbox 事件。

## 10. 客服上下分审批

状态流：

```text
PENDING_FINANCE
  -> CLOSED_REJECTED
  -> PENDING_ADMIN（超过管理员阈值）
  -> APPROVED
  -> EXECUTED
```

- 客服提交时检查其允许用户范围、单笔额度和当日累计额度。
- 财务复核全部请求。
- 超过配置阈值时由管理员使用 TOTP 二次审批。
- 执行前再次检查权限、额度、用户状态和幂等键。
- 系统自动生成标准原因码；人工备注和凭证选填。
- 审批和执行必须由不同权限动作驱动，不允许客户端直接更新余额。

## 11. 积分红包

### 11.1 类型与限制

- 群聊等额红包
- 群聊拼手气红包
- 私聊等额红包
- 私聊拼手气红包
- 单红包最多100份、最高10000积分、每份至少0.01积分。
- 有效期24小时，不收手续费。

### 11.2 状态与资金

创建时从发送者可用积分转入红包托管账户，并在同一事务中预生成全部份额。

```text
ACTIVE -> COMPLETED
ACTIVE -> EXPIRED -> REFUNDED
ACTIVE -> CANCELLED_PARTIAL
```

- 等额红包按分拆分，除不尽的余数依次加到前若干份。
- 拼手气红包使用密码学安全随机数，份额总和必须严格等于总额。
- 同一用户对同一红包最多领取一次。
- 领取以条件更新、唯一约束和数据库锁保证同一份额只成功一次。
- 24小时后自动退还未领取余额。
- 获授权客服或管理员可撤销异常红包，只退还尚未领取部分。

Flutter 先调用业务 API 创建红包，再将不可猜测的 `red_packet_id` 放入 E2EE Matrix 自定义事件。接收端解密后向业务 API 查询和领取。

## 12. USDT-TRC20 托管钱包

### 12.1 范围

- 只支持 USDT-TRC20。
- TP/imToken 等属于用户侧外部钱包。
- 平台通过 `CustodyProvider` 接口连接专业托管服务。
- 开发和测试使用 `SandboxCustodyProvider`；生产适配器在供应商确定后实现。

### 12.2 统一托管接口

```python
class CustodyProvider(Protocol):
    async def allocate_deposit_address(self, user_id: UUID) -> DepositAddress: ...
    async def get_deposit(self, provider_reference: str) -> ProviderDeposit: ...
    async def create_withdrawal(self, request: ProviderWithdrawalRequest) -> ProviderWithdrawal: ...
    async def get_withdrawal(self, client_order_id: str) -> ProviderWithdrawal: ...
    def verify_webhook(self, headers: Mapping[str, str], body: bytes) -> VerifiedWebhook: ...
```

### 12.3 充值

```text
ADDRESS_ALLOCATED -> DETECTED -> CONFIRMING -> CREDITED
                                  -> MANUAL_REVIEW
```

- 最低充值1 USDT。
- 充值达到20个确认后到账。
- 低于最低金额进入人工处理队列，不自动入账。
- Webhook 只作提示；必须调用托管商查询接口核验网络、币种、地址、金额和状态。
- `network + tx_hash + log_index` 唯一，重复回调不得重复入账。
- 入账通过 USDT 复式账本完成。

### 12.4 提现

```text
REQUESTED -> FUNDS_FROZEN -> PENDING_FINANCE
          -> PENDING_SECOND_APPROVAL（金额 >= 1000 USDT）
          -> PROVIDER_SUBMITTED -> BROADCAST -> CONFIRMED
          -> FAILED_REFUNDED（仅提交托管商前或确定失败）
```

- 最低提现10 USDT。
- 所有提现经过财务审核。
- 单笔达到1000 USDT 时需要双人审批和 TOTP。
- 冻结金额为提现金额、托管商实际费用和后台配置的平台固定费用之和。
- 地址执行格式校验、地址簿校验和风险黑名单检查。
- 调用托管商使用稳定的 `client_order_id`。
- 请求超时或结果未知时只能查询原订单，不能创建第二笔提现。
- 已提交托管商的提现不可取消。

### 12.5 对账

- 每小时增量核对充值、提现和在途订单。
- 每日全量核对托管余额、内部资产账户、用户负债和费用。
- 发现差异立即暂停自动提现、告警并创建人工调查记录。
- 链上回滚通过冲正交易处理，禁止修改原始入账。

## 13. API、错误与幂等

### 13.1 API 分组

- `/api/v1/auth/*`
- `/api/v1/invitations/*`
- `/api/v1/devices/*`
- `/api/v1/support/*`
- `/api/v1/ledger/*`
- `/api/v1/point-transfers/*`
- `/api/v1/adjustments/*`
- `/api/v1/red-packets/*`
- `/api/v1/wallet/deposits/*`
- `/api/v1/wallet/withdrawals/*`
- `/api/v1/admin/*`
- `/api/v1/webhooks/custody/{provider}`

### 13.2 错误结构

```json
{
  "code": "LEDGER_INSUFFICIENT_FUNDS",
  "message": "Insufficient available balance.",
  "trace_id": "01J...",
  "field_errors": []
}
```

客户端按稳定 `code` 处理，不依赖英文 `message`。资金写接口强制 `Idempotency-Key`；同一键相同参数返回原结果，不同参数返回 `IDEMPOTENCY_CONFLICT`。

### 13.3 Outbox

业务状态、账本和 Outbox 在同一事务提交。Worker 使用可重入消费者投递 Matrix 系统通知、邮件、推送和内部事件。通知失败不能回滚已经成功的资金事务。

## 14. React 管理后台

后台包含：

- 邀请码、用户和封禁管理。
- 官方客服角色、编号、技能、用户范围和额度。
- 客服队列、工单、转接、关闭和统计。
- 上下分提交/审批/管理员复核。
- 账本交易、分录、冲正和手续费查询。
- 红包异常撤销和审计。
- USDT 充值、提现、双人审批、对账差异和托管状态。
- TOTP、角色权限、审计日志和配置历史。

管理后台不能读取普通 E2EE 房间。只有用户主动提交的举报材料可在授权页面查看。

## 15. 安全、配置与运维

- 密码使用现代内存困难哈希；访问 Token 短期有效，Refresh Token 轮换并可撤销。
- 管理员敏感操作要求 TOTP 和近期重新认证。
- RBAC 在服务端执行，前端隐藏按钮不能替代鉴权。
- Webhook 验签、校验时间戳、防重放，并主动查询供应商确认。
- 生产密钥来自 Secret Manager；开发使用显式测试密钥。
- 运行数据、签名密钥、`.env` 和数据库目录不得进入源码分发包。
- 日志使用结构化字段和 `trace_id`，资金事件必须包含操作者、原因码和关联业务 ID。
- 监控覆盖 API、队列、Matrix 同步、账本失败、红包过期、托管延迟和对账差异。
- 数据库和密钥备份加密保存，并定期执行恢复演练。

## 16. 当前项目必须先修复

1. `scripts/init_matrix.ps1` 的模板标记计算只匹配单花括号，导致生成配置残留外层花括号。必须改为严格替换 `{{KEY}}` 并添加自动测试。
2. 删除已生成的错误 Synapse/Element 配置并通过安全流程重新生成。
3. 将 `matrixdotorg/synapse:latest` 和 `vectorim/element-web:latest` 替换为验证并锁定的版本。
4. 将现有 `matrix-bot` 重命名/约束为通知 Bot，禁止自动加入普通房间。
5. 分离运行数据和源码；建立 `.env`、数据库目录和签名密钥检查。
6. 为现有 Python 服务补充 pytest、类型检查、lint 和容器健康验证。

## 17. 测试策略

### 17.1 单元与性质测试

- 手续费舍入与最小手续费。
- 任意账本交易分录恒等为零。
- 用户可用余额永不为负。
- 幂等重放返回同一结果，参数变化返回冲突。
- 等额/随机红包份额总和和最小份额。
- 审批状态机只允许合法转移。

### 17.2 集成测试

- 使用真实 PostgreSQL、Redis 和测试 Synapse。
- 并发转账、并发红包领取和重复 Webhook。
- 托管商回调乱序、重复、延迟、超时和未知结果。
- Outbox 提交、重试和消费者幂等。
- Matrix 多设备验证、密钥备份恢复和成员变更后的密钥轮换。

### 17.3 端到端与容量

- Android/iOS：注册、邮箱验证、设备恢复、聊天、客服、转账、红包、充值和提现。
- React 后台：上下分审批、双人提现审批、对账和审计查询。
- 账本峰值50 TPS。
- 500人群组同步。
- 弱网下消息重试、附件续传和一对一通话恢复。
- 备份恢复和灾难恢复演练。

## 18. 发布验收

### 18.1 功能验收

- 用户可使用邀请码、用户名、密码和已验证邮箱注册，无实名和手机号字段。
- 官方客服标识无法由普通用户伪造。
- Android/iOS 可完成 E2EE 私聊、群聊、附件、语音消息和一对一语音/视频通话。
- 积分转账严格收取0.5%且最低0.01积分手续费。
- 上下分遵守范围、额度、财务和管理员审批。
- 四种积分红包均正确处理并发、过期和异常撤销。
- USDT-TRC20 充值和提现通过 Sandbox 托管契约全流程验收。

### 18.2 安全验收

- 服务端、数据库、对象存储、日志和推送中找不到普通消息明文。
- 丢失恢复密钥时平台不能解密历史消息。
- 任意资金操作均存在平衡分录、幂等键、操作者、原因码和审计记录。
- 重复托管回调和未知结果重试不会造成重复入账或提现。

### 18.3 工程验收

- 格式化、lint、类型检查、单元、集成和 E2E 测试全部通过。
- 数据库迁移可在生产副本演练。
- 容器版本锁定且没有 `latest`。
- 运维手册覆盖部署、回滚、备份恢复、托管故障、对账差异和密钥轮换。

## 19. AGENT 设计规范

### 19.1 Agent 角色

1. **Root Orchestrator：**维护规格、任务依赖、契约和最终集成。
2. **Foundation Agent：**配置修复、CI、数据库、部署和可观测性。
3. **Identity & Support Agent：**注册、邮箱、邀请码、RBAC 和客服工单。
4. **Ledger & Redpacket Agent：**复式账本、审批、转账和红包。
5. **Wallet & Custody Agent：**充值、提现、托管适配、Webhook 和对账。
6. **Matrix & E2EE Agent：**设备密钥、房间、附件、RTC 和 TURN。
7. **Flutter Agent：**Android/iOS UI、本地密文缓存和业务卡片。
8. **Admin Web Agent：**React 客服、财务和审计工作台。
9. **Quality & Security Agent：**规格审查、安全审查、集成、压力和恢复测试。

### 19.2 AGENTS.md 分层

- `/AGENTS.md`：全局不变量、标准命令、完成定义和协作规则。
- `apps/mobile_flutter/AGENTS.md`：E2EE、密钥、Flutter 和本地存储规则。
- `apps/admin_web/AGENTS.md`：RBAC、审批、OpenAPI 客户端规则。
- `services/business-api/AGENTS.md`：模块边界、事务、错误和 API 规则。
- `services/business-api/app/modules/ledger/AGENTS.md`：账本不变量和受保护变更。
- `services/business-api/app/modules/wallet/AGENTS.md`：托管、幂等和对账规则。
- `infra/AGENTS.md`：密钥、版本锁定、数据卷和部署规则。

### 19.3 工作流

1. 阅读本规格、相关 ADR 和作用域 `AGENTS.md`。
2. 从批准的实施计划领取一个边界明确的任务。
3. 在独立 worktree/分支中工作并声明文件所有权。
4. 先写失败测试，记录失败原因。
5. 实现最小变更，执行模块测试。
6. 执行完整门禁并保存验证输出。
7. 先做规格符合性审查，再做质量/安全审查。
8. Root 执行跨模块集成测试后合并。

### 19.4 禁止事项

- 禁止直接修改余额或历史账本。
- 禁止用浮点数表示资产。
- 禁止让服务端取得用户明文、恢复密钥或会话密钥。
- 禁止让 Matrix 消息决定资金状态。
- 禁止对未知托管结果盲目重试。
- 禁止提交秘密、生产地址、运行数据和未脱敏日志。
- 禁止使用 `latest`、跳过迁移测试或静默改变 OpenAPI。

### 19.5 受保护变更

账本结构、手续费公式、红包算法、提现状态机、托管契约、E2EE、密钥备份、认证、RBAC、TOTP、OpenAPI 破坏性变化和破坏性迁移必须先更新 ADR/规格，并经过领域与 Quality/Security 双重批准。

### 19.6 Agent 完成定义

- 需求具有可追踪测试和失败到通过的证据。
- 格式化、lint、类型检查、单元和集成测试通过。
- API、迁移、配置和运维文档同步更新。
- 没有占位符、硬编码秘密、临时绕过或未处理警告。
- 资金不变量、E2EE 边界和幂等规则经过专项验证。
- 提交小而可回滚，使用约定式 Commit 信息。

## 20. 分阶段交付顺序

1. 基础配置修复、测试基线、版本锁定和仓库规范。
2. 业务后端骨架、身份、邮箱、邀请码、RBAC 和审计。
3. 客服目录、排队、转接和官方标识。
4. 复式积分账本、上下分审批和积分转账。
5. 红包状态机和 E2EE 业务卡片。
6. Sandbox USDT 托管、充值、提现和对账。
7. Flutter Android/iOS 的 Matrix E2EE 聊天、密钥恢复和业务页面。
8. 一对一 E2EE 语音/视频通话与 TURN/SFU。
9. React 管理后台。
10. 生产托管商适配、全链路压测、安全审查和发布演练。

生产托管商名称和平台固定提现费属于部署配置决策，不影响接口与核心状态机。开发阶段必须使用 Sandbox 适配器；正式适配器必须通过同一套契约测试后才能启用。
