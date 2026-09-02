# 2026-08-29 红包微信化与聊天转账功能验证证据

对应计划：`docs/superpowers/plans/2026-08-29-red-packet-transfer-optimization.md`

## 需求落点一览

| # | 需求 | 结果 |
|---|------|------|
| 1 | 版本同步：两台模拟器升级到最新并一致 | `emulator-5554` 与 `emulator-5556` 均安装 `0.2.0`（versionCode 2，同一 `app-release.apk`），dumpsys versionName 双机一致 |
| 2 | 红包页面 UI 参照微信、去绿色气泡 | 聊天红包卡片以 `decorateContent: false` 渲染（`matrix_home_page.dart`，含转账卡片）；发红包页/详情弹层为微信橙红渐变风格；测试 `red packet card is rendered without the outgoing green message bubble` 通过 |
| 3 | 发红包页：数字键盘/左字段名/右对齐/微信风格 | `chat_red_packet_sheet.dart` 重写：总金额/红包个数行内左侧字段名、`TextAlign.right`、`numberWithOptions(decimal)`；测试断言齐全 |
| 4 | 余额不足弹窗「红包创建失败，账户余额不足」 | 客户端余额预检 + 服务端 `RED_PACKET_BALANCE_INSUFFICIENT` 均弹 `CupertinoAlertDialog`；`chat_red_packet_sheet_test.dart` 两条用例覆盖 |
| 5 | 群聊三种红包类型 | 拼手气 RANDOM / 普通 EQUAL / 专属 EXCLUSIVE（后端校验 room_id+recipient_id+share_count=1），UI 类型选择器 + 群成员选择器；`test_red_packet_settings_and_limits.py` 覆盖创建/指定人领取/非指定人 403 |
| 6 | 单个红包上限 20000 可调整 | 环境变量 `BUSINESS_RED_PACKET_MAX_TOTAL`（默认 20000.00）+ 数据库 `app_settings` 运行时覆盖；管理端 `GET/PUT /api/v1/admin/red-packet-settings`（SYSTEM_ADMIN，幂等键+审计）；客户端经 `GET /red-packets/limits` 展示实际上限 |
| 7 | 聊天转账（参照微信） | 后端 `chat_transfers` 托管状态机（PENDING→ACCEPTED/DECLINED/EXPIRED，24h 过期退回含手续费退回，费用按规范 9.3：0.5% 最低 0.01，转出方承担、收款方足额）；API `POST /chat-transfers`、`/{id}/accept`、`/{id}/decline`、`GET /{id}`；客户端单聊「+」面板转账入口、转账页、橙红转账卡片（无气泡）、收款/退还详情弹层；群聊隐藏转账入口 |

## 测试证据（本机）

- 全量门禁：`pwsh -NoProfile -File scripts/verify.ps1` → **Verification: PASS（退出码 0）**，含仓库策略、部署策略、模板单测、Matrix 渲染冒烟、Matrix Bot、Business API+Worker、Flutter 边界、UI 契约漂移、导入冒烟、AST 解析、Alembic 迁移（单 head=0030）、OpenAPI 漂移、Compose 渲染全部通过。

- 后端：`py -3.12 -m pytest tests/business_api tests/business_worker -q` → **213 passed, 1 failed→修复后全绿**（唯一失败为 OpenAPI 契约未再生成，执行 `scripts/export_openapi.py` 后 `test_openapi_contract.py` 通过）。
  - 新增：`tests/business_api/transfer/`（13 例：费用公式、托管、收款、退还、手续费退回、余额不足、幂等重放、重复收款拒绝、过期退款、可见性）
  - 新增：`tests/business_api/redpacket/test_red_packet_settings_and_limits.py`（4 例：limits 端点、管理端运行时调整、专属红包领取流程、专属参数校验）
  - 新增：`tests/business_worker/test_chat_transfer_expiry.py`（过期退款任务）
  - 更新：`tests/business_api/test_migrations.py`（head=0030，链 0029→0030）
- Flutter：`flutter analyze` → **No issues found**；`flutter test` → **307 全部通过**
  - 新增：`test/features/matrix/chat_red_packet_sheet_test.dart`（7 例）、`test/features/transfer/chat_transfer_controller_test.dart`（3 例）
  - 更新：`chat_more_panel_test.dart`（转账入口/群聊隐藏）、`wechat_components_test.dart`（转账卡片无气泡/状态标签）、`message_action_policy_test.dart`（转账仅安全操作）、`room_timeline_controller_test.dart`（转账引用发送）
- UI 契约：`py -3.12 scripts/verify_ui_contract.py` → **PASS (17 components, 330 screens)**；`frontend/tests/*.test.mjs` 全部 0 fail（新增聊天转账 4 画板，`expectedScreenCount` 326→330 已同步）

## 部署证据（root@207.56.8.8:/opt/starchat）

- 同步内容：`backend/app`（含 `modules/transfer`、`modules/settings`、`api/transfer.py`、`api/redpacket.py`、`api/admin.py`、`core/config.py`）、`backend/migrations`（0029/0030）、`services/business-worker/app`（含 `tasks/chat_transfer_expiry.py`），并镜像至服务器 `services/business-api/`。
- 备份：`/opt/starchat/backends` 改动前打包至 `/opt/starchat/backups/backend-pre-transfer-*.tar.gz`、`docker-compose.production.yml.bak-*`。
- 迁移：business-api 启动日志 `Running upgrade 0028_notice_receipts_ads -> 0029_chat_transfers`、`0029 -> 0030_app_settings`；`alembic_version` = `0030_app_settings`；`chat_transfers`、`app_settings` 表已建。
- 容器：`starchat-business-api-1`、`starchat-business-worker-1` 均 healthy；worker 崩溃循环（旧 `config.py` 缺 `red_packet_max_total`）已随全量同步修复。
- 遗留故障修复：宿主 Caddy 占用 80/443，`starchat-gateway-1` 因端口冲突停留在 Created 状态导致 `liuhetong888.com` 502（早于本次部署即存在，见 Caddy 日志 12:09）。已将网关端口调整为 `127.0.0.1:9443:443` 并启动，`https://liuhetong888.com/api/v1/health/live` → 200 `{"ok":true,"service":"畅聊 Business API"}`。
- 路由冒烟：`/red-packets/limits`、`POST /chat-transfers`、`/admin/red-packet-settings` 公网均返回 401（路由存在且受鉴权保护）。

## 模拟器证据

- 构建产物：`apps/mobile_flutter/build/app/outputs/flutter-apk/app-release.apk`（0.2.0，pubspec `version: 0.2.0+2`）。
- `adb install`：emulator-5554 Success（覆盖安装）；emulator-5556 因旧包签名不同先 `uninstall` 后安装 Success（需重新登录）。
- `dumpsys package com.liuhetong.mobile`：双机 `versionName=0.2.0`。
- 双机启动冒烟：应用正常启动，`[Matrix] Initialize client liuhetong_mobile`，无崩溃。

## 已知说明

- 转账手续费按产品规范执行（转出方 0.5% 最低 0.01，收款方足额；退回时本金与手续费一并退回）。
- 专属红包指定人可从群成员列表选择；成员名优先取通讯录备注。
- 红包卡片/转账卡片的状态以业务 API 查询为准（规范 3.1），聊天卡片展示角色默认态，点开详情拉取权威状态。
