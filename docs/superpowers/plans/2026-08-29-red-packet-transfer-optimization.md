# 2026-08-29 红包与聊天转账微信化优化计划

## 需求（来自产品验收要求）

1. 版本同步：两台模拟器安装同一最新版本 APK。
2. 红包领域页面 UI 参照微信红包：聊天内红包卡片不再套绿色气泡，视觉与微信红包一致。
3. 发红包页面：数字键盘；每行输入框左侧显示字段名（总金额/红包个数等）；输入内容右对齐；整体 UI 与微信发红包页一致。
4. 余额校验：红包金额超过点钻余额时弹出「红包创建失败，账户余额不足」。
5. 群聊红包三种类型：拼手气红包（RANDOM）、普通红包（EQUAL）、专属红包（EXCLUSIVE）。
6. 单个红包点钻上限 20000，且可通过后台/配置调整。
7. 新增聊天「转账」功能，逻辑与 UI 参照微信。

## 现状（工作区已含部分改动）

- 后端 `EXCLUSIVE` 模式、`BUSINESS_RED_PACKET_MAX_TOTAL` 环境配置、创建路由错误翻译（含「红包创建失败，账户余额不足」）已在工作区；OpenAPI 已再生成。
- Flutter 聊天红包卡片已不再套气泡（`decorateContent: kind != redPacket`）；发红包表单已有三类型与右对齐输入，但视觉仍为普通表单，未微信化；无余额弹窗、无成员选择器、无转账。
- 服务器 `starchat-business-worker-1` 因部署不一致（旧 `backend/app/core/config.py` + 新 worker `main.py` 引用 `red_packet_max_total`）崩溃重启，需随本次部署修复。
- 部署事实：Docker 构建与 `scripts/verify.ps1` 均使用仓库根未跟踪镜像目录 `backend/`，任何 `services/business-api` 改动必须同步到 `backend/`。
- 模拟器：emulator-5554 未安装应用，emulator-5556 为 0.1.0；应用默认连接 `https://liuhetong888.com`。

## 任务分解与文件归属

### A. 后端（services/business-api，完成后同步 backend/）

A1. 聊天转账模块 `app/modules/transfer/`：
- `models.py`：`ChatTransfer`（chat_transfers：id、sender_id、receiver_id、amount、fee、note、status PENDING/ACCEPTED/DECLINED/EXPIRED、idempotency_key、expires_at、created_at、updated_at；唯一 (sender_id, idempotency_key)）。
- `service.py`：`ChatTransferService`，遵循规范 9.3：`fee = max(0.01, 0.005×amount)`；创建：发送者扣 amount+fee，金额入 `PLATFORM_TRANSFER_ESCROW:{id}`，fee 入 `PLATFORM_FEE`（scope `chat_transfer.create`）；accept：托管→接收者全额（scope `chat_transfer.accept`）；decline/expire：托管→发送者 + fee 退还（scope `chat_transfer.refund`）；行级锁、幂等重放、24h 过期。
- `app/api/transfer.py`：POST `/chat-transfers`、POST `/{id}/accept`、`/{id}/decline`、GET `/{id}`；余额不足映射 `CHAT_TRANSFER_BALANCE_INSUFFICIENT`「转账失败，账户余额不足」。
- 迁移 `0029_chat_transfers.py`。

A2. 上限运行时可调：
- 迁移 `0030_app_settings.py` + `app/modules/settings/service.py`（app_settings 键值表，`red_packet_max_total` 键）。
- 管理端：GET/PUT `/admin/red-packet-settings`（SYSTEM_ADMIN，幂等键、审计）。
- 红包创建从 DB 设置读取（回退环境配置）；新增 GET `/red-packets/limits` 返回 `{max_total, max_share_count, min_per_share}` 供客户端展示。
- worker：`app/tasks/chat_transfer_expiry.py` 过期退款任务，接入 `app/main.py`。

A3. 测试（先红后绿）：
- `tests/business_api/transfer/test_chat_transfer.py`（费用公式、创建/收款/退还全链路、余额不足、幂等重放、重复收款拒绝、过期退款）。
- `tests/business_api/transfer/test_chat_transfer_api.py`（API 全流程与错误封装）。
- redpacket 测试补 EXCLUSIVE、limits、管理端设置生效。
- `tests/business_worker/test_chat_transfer_expiry.py`。
- `scripts/export_openapi.py` 再生成 OpenAPI。

### B. Flutter（apps/mobile_flutter）

B1. 发红包页微信化（`chat_red_packet_sheet.dart` 重写）：橙红渐变页面、白色圆角表单卡（行：总金额/红包个数/祝福语，左字段名右对齐输入、数字键盘）、类型选择（三种，微信样式）、专属红包成员选择器（群成员列表）、「塞钱进红包」按钮、退款说明与上限提示（取自 `/red-packets/limits`）。
B2. 余额校验：进入页面取余额，提交时本地预检 + 服务端错误码映射，均弹 `CupertinoAlertDialog`「红包创建失败，账户余额不足」。
B3. 聊天转账：`ChatMorePanel` 增加转账入口（仅单聊显示）；`chat_transfer_sheet.dart`（转账给 XX、金额、转账说明、手续费提示、转账按钮）；`chat_transfer_controller.dart`；`WeChatTransferCard` 聊天卡片（橙红、金额、待收款/已收款/已退还、畅聊点钻转账 footer、无气泡）；收款详情弹层（收款/退还）；时间线 `com.changliao.transfer` 消息与视图模型；`business_api_client` 增加四个转账方法与 `redPacketLimits`。
B4. 红包详情弹层微信风格化（`red_packet_detail_sheet.dart`）。
B5. 版本 `0.2.0+2`；`flutter analyze`、`flutter test` 全绿；新增/更新测试。

### C. design-demo 同步

- 红包创建页微信化样式、新增聊天转账卡片/页面组件；`npm test`（component-contracts）保持绿。不改 `frontend/`（UI 契约 expectedScreenCount=326 不变）。

### D. 版本同步与部署

- 构建统一 APK，`adb install -r` 安装至 emulator-5554/5556，`dumpsys` 验证两台 versionName 一致。
- 同步 `services/business-api`→`backend/`，同步代码至服务器 `/opt/starchat`，重建 business-api 与 business-worker 镜像（修复 worker 崩溃），迁移 `alembic upgrade head`。
- `pwsh -NoProfile -File scripts/verify.ps1` 全绿；证据写入 `docs/verification/2026-08-29/`。

## 财务与安全不变量（断言覆盖）

- 每笔资金写入有幂等键、稳定 reason_code、actor、审计与 Outbox（沿用 LedgerService.post）。
- 账本分录逐笔平衡；用户余额不为负；托管账户按转账/红包隔离。
- 手续费严格 0.5% 最低 0.01，转出方承担、接收方足额到账（规范 9.3）。
- 卡片仅为 E2EE 展示载体，真实状态从业务 API 查询（规范 3.1）。
- 不引入 CAIBI/USDT 兑换、USDT 转账/红包。
