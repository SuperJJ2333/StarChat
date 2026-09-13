# 财务实装缺口与拍一拍修复计划

**Goal:** 修复六项审计缺口、统一群转账/专属红包选择器，并落实每用户每房间 60 秒最多三次拍一拍。
**授权:** 用户已确认修复审计中所有问题，并补充金额实际右对齐、名称、统一选择器、正确头像及限频要求；无需再次批准既定 demo。仅本地实现及自动化验证，本轮不自行生产部署。
**Architecture:** 业务 API 权威财务 ID/金额/状态；ProfileRepository 提供账号隔离的备注昵称投影；Matrix 负责群成员及加密头像。共享选择器显示统一身份并在提交前解析业务 ID，禁止将 Matrix ID 当业务 ID。限频在发送入口原子预留配额，按用户与房间计数，失败仅释放自己的预留。
**Tech Stack:** Flutter/Dart、既有业务 API、Matrix SDK、HTML demo 与 UI registry。

## 基线和分工

- 基线 c5cd589c；隔离工作树 .worktrees/finance-six-remediation，保留主目录其他任务未提交修改。
- 主代理 Astra：设计、计划、调用链和实际 diff 审查、门禁核对。
- 显式模型 gpt-5.6-terra 执行两个独立批次；同一文件不得并发编辑。
- T1 所有权：ledger 模块、app_home.dart、chat_transfer_detail_sheet.dart、ledger UI 测试。可新增 ledger identity/presentation 文件；不要编辑 ProfileRepository 或业务 API 公共模型，接口需求先告知主代理。
- T1 经调用链审查追加：finance_message_entry.dart 的身份依赖透传；statements.py/api/ledger.py 与必要的 main.py 依赖注入、对应服务端测试和 OpenAPI。仅为已授权账单的对手方通过 ProfileService.read_public_profile_identities 一次批量读取公开昵称/畅聊号，新增兼容可空字段；不新增公开备注，不改变任何财务写入。已确认没有按业务 ID 查询非好友的现有客户端资料 API。
- T2 所有权：room_page.dart、chat_transfer_sheet.dart、chat_red_packet_sheet.dart、nudge_service.dart、新共享成员选择器与限频文件、对应测试。T2 内先完成选择器，再修改同文件拍一拍。
- T3 由 T1 完成后串行：frontend demo/catalog、UI registry；此阶段不得与其他子代理写共享前端文件。

## T1 账单（审计 1/2/3/4）

- [x] 写失败测试并记录 RED：金额右边界在长短标题/大字体下相同；好友备注→昵称→账号，身份晚到/更新会刷新；全部入口身份依赖连通；转账/红包详情符合 demo 字段。
- [x] 金额列占整行尾部固定边界，不能只在内容宽度内 right-align；精确金额格式化，不引入 double 资产计算。
- [x] 修复字面量 $peer，接入真实入口及详情返回入口，异步身份加载不阻塞账单并保持账号隔离。
- [x] Flutter 详情实装 ledger-detail-redesign-demo.html 的分类图标、大金额、状态、交易对方、说明、金额/手续费/时间、ID复制、红包类型及全部账单导航；金额和业务状态仍读 API。
- [x] 运行账单与转账详情相关测试，检查超长名称、空态、失败、隐私及失效会话边界。

## T2 成员选择器与拍一拍（审计 5/6，新增 3/4）

- [x] RED：两个入口共用同一选择器；HTTP/MXC 头像能进入正确渲染器；空群成员不得加载全好友；非好友 Matrix ID 转为真实业务 ID 或禁止提交并提示。
- [x] 统一选择器外观与交互：标题/搜索/列表/头像/备注昵称/选中反馈/加载失败重试；好友优先业务头像，非好友使用已有 Matrix 头像组件。
- [x] 群转账和专属红包提交前核对业务 ID；保留支付密码、金额精度、幂等及人数上限。覆盖空白红包数量拒绝提交。
- [x] 限频 RED：同用户同房间前三次允许、第四次拍任何人都拒绝；不同房间/用户隔离；60 秒边界；并发失败不能释放别人的令牌；退出重进房间不重置仍有效窗口。
- [x] 实装共享限频服务与真实 toast；发送失败释放本次预留；所有正常拍一拍发送路径共用限频入口。
- [x] 定向测试 GREEN 并提交实现说明；不触碰财务账本、E2EE 协议或服务端财务状态机。

## T3 UI 合约和最终验证

- [x] 更新 HTML demo/catalog 与 registry，对照已批准详情设计，展示统一选择器及限频 toast；不操作 Figma。
- [x] Astra 先逐项规格审查再质量/安全审查，发现具体问题交回 Terra 修复。
- [x] 预检依赖/工具/verify 环境；运行 Flutter analyze、相关回归、UI contract、frontend tests、scripts/verify.ps1；全量结果标明基线失败，不以定向通过冒充全量。
- [x] 记录实际命令/退出码/源码与锁文件身份、未验证真机项，保存独立任务和验收报告。完成本地集成时保留其他修改。

## 验收边界

拍一拍采用滚动 60 秒窗口：最早一次满 60 秒后恢复一个名额；限频应跨页面重建保持。客户端限制不声称能防止其他客户端绕过或跨设备全局限频，若需全局强制需服务端加密事件策略另行设计。真机由用户验证，不操作真实资金测试。
