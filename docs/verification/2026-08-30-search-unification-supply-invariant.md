# 搜索入口统一 / 标题过渡 / 点钻总量不变式 — 验证证据（2026-08-30）

精准缺陷描述与验收标准：`docs/superpowers/plans/2026-08-30-search-unification-supply-invariant.md`。

## 缺陷一：手续费账务规则 → 发行量不变式（验收通过）

- 新增 `tests/business_api/ledger/test_supply_invariant.py`（**2 passed**）：
  - 种子：发行 alice 400.00 + bravo 600.00（`PLATFORM_CLEARING` -1000.00 镜像）；
  - 流程覆盖：红包创建（托管）→ 领取；转账创建（含 0.5% 手续费 0.03，最低 0.01）→ 接收；转账过期退回（本金 + 手续费回发送方）；
  - 断言：流通总量（全部账户扣除 `PLATFORM_CLEARING`）恒为 1000.00；`PLATFORM_CLEARING` 恒为 -1000.00；`PLATFORM_FEE` 恰为手续费累计且过期退回后清零；红包/转账托管科目清零；每笔交易分录之和为 0；审计（`ledger.post`）与 Outbox（`ledger.posted`）事件数量与账务笔数一致（可追溯）。
- 实现核实：红包链路分录无手续费科目（`RED_PACKET_*` reason codes）；转账手续费进入官方 `PLATFORM_FEE` 科目（`TRANSFER_FEE_RATE=0.5%`，`max(0.01, round-half-up(0.5%×金额))`）。

## 缺陷二：搜索入口与标题过渡（修复完成）

- **入口统一**：`GlobalSearchPage` 新增 `matrix` 数据源参数（页面自行加载群聊名与最后一条本地消息摘要）；「消息 / 通讯录 / 发现」三个搜索 icon 现以相同构造 `GlobalSearchPage(api:, matrix:)` 打开，呈现完全一致的分区（朋友 / 群聊 / 聊天记录）。相关参数贯通：`MatrixHomePage`、`ContactsTabPage → ContactsPage`、`DiscoveryPage`（新增 `matrix` 字段，`app_home.dart` 注入）。
- **标题过渡**：四个导航栏（消息 / 通讯录 / 发现 Tab 根页 + 统一搜索页）设置 `transitionBetweenRoutes: false`，去除 Hero 飞行；标题随页面标准转场（~300ms Cupertino 滑入）整体出现，无空白停顿与跳变。

## 验证

| 项目 | 结果 |
| --- | --- |
| `pytest tests/business_api/ledger/test_supply_invariant.py` | **2 passed** |
| `pytest tests/mobile/test_search_entry_uniformity.py` | **3 passed** |
| `flutter analyze` | No issues found |
| `flutter test` | **366 passed**（新增统一搜索页契约 1 项） |
| `verify.ps1` 全量 | **PASS** |

## 部署说明

- 后端无代码变更（账务规则已由既有实现满足，本批补齐可执行验收）；不变式测试进入 `verify.ps1` 常规门禁。
- 客户端改动（搜索统一 + 标题过渡）随下个版本包分发；旧包用户升级路径不受影响。
