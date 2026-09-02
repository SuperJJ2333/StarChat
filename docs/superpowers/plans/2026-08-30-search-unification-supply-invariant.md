# 精准缺陷描述与验收标准（2026-08-30）

## 缺陷一：红包/转账手续费账务规则的精准化

### 具体表现（现状）
- 红包（点钻支付）不收手续费：创建时借记发送方 `total`，全额进入红包托管 `PLATFORM_RED_PACKET:{packet_id}`，领取/退回在托管与用户科目间划转，任何环节不触碰手续费科目。
- 转账收手续费：`TRANSFER_FEE_RATE = 0.5%`，单笔最低 0.01（四舍五入到分）。创建时分录为 `发送方 -(金额+手续费)` / `托管 +金额` / `PLATFORM_FEE(官方) +手续费`；接收确认时托管→接收方；过期退回时本金+手续费均退回发送方。

### 精准化后的可验证账务逻辑（不变式）
设系统点钻累计发行量为 `I = 1000.00`（账本以 `PLATFORM_CLEARING = -I` 作为发行镜像科目）：
1. **守恒不变式**：任意时刻，除 `PLATFORM_CLEARING` 外全部科目（用户钱包 + 红包/转账托管 + 官方手续费钱包）余额之和恒等于 `I`；`PLATFORM_CLEARING` 恒等于 `-I`。任何支付、转账、手续费或其他操作都不改变该值，直到发生一笔显式的发行/销毁调整（独立 reason_code + 审计）。
2. **平衡不变式**：每笔 `LedgerTransaction` 的全部科目金额之和恒为 0（复式记账）。
3. **可追溯不变式**：每笔交易携带 `reason_code`（如 `RED_PACKET_CREATE/CLAIM/REFUND`、`CHAT_TRANSFER_CREATE/ACCEPT/EXPIRE`、`CHAT_TRANSFER_FEE_REFUND`），并同步写入审计事件（`ledger.post`）与 Outbox 事件（`ledger.posted`）；手续费收入可由 `PLATFORM_FEE` 科目余额直接对账。
4. **无费规则**：红包链路（创建/领取/退回）不产生 `PLATFORM_FEE` 科目变动；转账链路手续费恰为 `max(0.01, round(0.5%×金额))`。

### 验收标准（已自动化）
`tests/business_api/ledger/test_supply_invariant.py`（2 项，通过）：
- 发红包 → 领取、转账 → 接收、转账过期退回全流程后，流通总量仍为 1000.00，`PLATFORM_CLEARING` 恒为 -1000.00，`PLATFORM_FEE` 恰为手续费累计，托管科目清零，每笔交易平衡，审计/Outbox 数量与账务笔数一致。

## 缺陷二：顶部导航栏搜索入口与标题过渡的精准化

### 具体表现与根因
1. 三个入口虽都构造 `GlobalSearchPage`，但构造参数不同 → 呈现内容不一致：
   - 消息页传 `rooms + messages`（含群聊、聊天记录区）；
   - 通讯录页仅传联系人加载器（只有"朋友"区）;
   - 发现页什么都不传（同样只有"朋友"区）。
2. 标题空白停顿：`CupertinoNavigationBar` 默认 `transitionBetweenRoutes: true`，路由切换时旧标题做 Hero 飞行（滑向后页返回键位并淡出）、新标题延迟淡入，造成标题区域先空白、后生硬出现。

### 精准化后的期望行为
1. **入口统一**：`消息 / 通讯录 / 发现` 三个 Tab 根页的搜索 icon（key：`messages-search` / `contacts-search` / `discovery-search`）全部指向同一个统一搜索页 `GlobalSearchPage`（页面导航 key：`global-search-nav`），以完全相同的构造（`api + matrix`）打开，呈现相同分区：朋友 / 群聊 / 聊天记录。群聊与聊天记录数据由页面通过注入的 Matrix 客户端自行加载（仅本地索引，不上传明文）。
2. **标题过渡**：四个导航栏（三个 Tab 根页 + 统一搜索页）设置 `transitionBetweenRoutes: false`，标题随页面标准 Cupertino 转场（约 300ms 滑入 + 视差）整体出现——动画连续、时长 ≤300ms，无空白停顿、无跳变。

### 验收标准（已自动化）
- 源码契约 `tests/mobile/test_search_entry_uniformity.py`（3 项，通过）：三入口均构造 `GlobalSearchPage(api:, matrix:)`；四导航栏均含 `transitionBetweenRoutes: false`；搜索页含 `global-search-nav` ID 与 matrix 数据源。
- 组件测试 `global_search_page_test.dart`：统一搜索页渲染共享导航标题、分区过滤行为回归通过。
