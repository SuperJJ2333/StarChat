# 红包功能仿微信优化及转账实现 — 收尾验证证据（2026-08-29）

任务来源：sess_89597a2d 交接待办（design-demo「我」页复核、版本号 0.3.0+3、verify.ps1、双模拟器构建安装、后端部署、证据文档）。
关联计划：`docs/superpowers/plans/2026-08-29-red-packet-transfer-optimization.md`、`docs/superpowers/plans/2026-08-29-email-login-transfer-darkmode.md`。

## 1. 改动清单

### Flutter 客户端（apps/mobile_flutter）

- 新增 `lib/core/amount_rules.dart`：共享金额校验（正数、≤2 位小数、格式校验）与 `TwoDecimalAmountFormatter`；红包 sheet 与转账 sheet 统一接入。
- 新增 `lib/features/transfer/`（chat_transfer_sheet）：联系人收款人选择（`BusinessApiClient.listContacts()`）、确认弹窗、错误弹窗统一 key。
- 新增 `lib/ui/finance/wechat_transfer_card.dart`：聊天内转账卡片。
- 新增 `lib/ui/components/wechat_nav_title.dart`：导航栏固定色深色标题（仅聊天页使用）。
- 删除 `lib/features/redpacket/redpacket_page.dart`：红包独立入口页移除（「我」页与 app_home 入口同步移除，红包仅保留聊天入口，仿微信）。
- `main.dart` 改 StatefulWidget + `WidgetsBindingObserver`，深色模式实时跟随系统；`WeChatTheme` 亮度自适应；4 个 Tab 根页固定背景 `tabRootBackground`。
- 登录错误文案「账号或密码错误」+ 邮箱格式校验；钱包页 TRC20 地址校验、提现轮询。
- `pubspec.yaml` 版本号 `0.2.0+2` → **`0.3.0+3`**。

### 后端（services/business-api，`backend/` 为同步副本）

- 新增 `app/api/transfer.py`、`app/modules/transfer/`、`app/modules/settings/`、`app/modules/admin/`。
- 迁移 `0029_chat_transfers`（聊天转账托管状态机）、`0030_app_settings`（运行时应用设置）。
- `app/api/identity.py`：登录用户名 `strip()` 后参与限流 key（13:32 部署后新增修复，本次部署上线）。
- business-worker 新增 `tasks/chat_transfer_expiry.py`（转账过期任务）。

### design-demo / 前端

- `frontend/src/screens/profile.js` 移除红包菜单项；`messaging.js`、`catalog/screens.js`、`styles/components.css` 同步更新。
- 测试契约同步：`tests/mobile/test_figma_ui_contract.py`「我」页标签期望移除 `红包`（红包入口移除后契约更新，21/21 通过）。

## 2. 测试结果

| 项目 | 命令 | 结果 |
| --- | --- | --- |
| Flutter 静态分析 | `flutter analyze` | No issues found |
| Flutter 单元/组件测试 | `flutter test` | **321 passed** |
| design-demo 契约测试 | `node --test frontend/tests/*.mjs` | **26 passed / 0 failed** |
| 仓库策略 | verify.ps1 → Test-RepositoryPolicy | PASS |
| 部署策略 | verify.ps1 → Test-DeploymentPolicy | PASS |
| Matrix Bot | verify.ps1 → pytest tests/matrix_bot | 9 passed |
| Business API + Worker | verify.ps1 → pytest tests/business_api tests/business_worker | 215 passed, 1 skipped |
| Flutter 边界契约 | verify.ps1 → pytest tests/mobile | 21 passed |
| UI 合同漂移 | verify_ui_contract.py | PASS |
| 迁移 | alembic heads（单头）/ offline upgrade | PASS（head = 0030_app_settings） |
| OpenAPI 漂移 | export_openapi.py --check | PASS |
| Docker Compose 渲染 | docker compose config | PASS |

## 3. 双模拟器验证

- 构建产物：`apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk`（230,042,119 字节，2026-08-29）。
- 安装方式：Git Bash 下 `adb install` 流式安装挂起，改用 `push + pm install`；emulator-5554 因签名不匹配先 `uninstall com.liuhetong.mobile`。
- emulator-5554：`pm install` Success；emulator-5556：`pm install` Success。
- 版本核验（dumpsys package）：两侧均 `versionName=0.3.0 versionCode=3`。
- 启动核验：monkey LAUNCHER 派发后两侧进程存活（pid 4987 / 8281，13 秒后复测未变）。
- 截图证据：`docs/verification/artifacts/2026-08-29/emulator-5554-launch.png`、`emulator-5556-launch.png`。

## 4. 生产部署证据

时间：2026-08-29T15:40Z（UTC）。服务器备份：`/opt/starchat/backups/20260829T154052Z/`（identity.py + 4 个前端文件 + 测试文件）。

差异核对（md5 逐文件）确认仅以下 6 个文件与服务器不一致，其余 backend/app、backend/migrations（114 个 .py）、services/business-worker、frontend 其余文件均逐字节一致：

- `backend/app/api/identity.py`（登录用户名 strip 修复）→ 同步后重建 `business-api` 镜像并重建容器。
- `frontend/src/catalog/screens.js`、`frontend/src/screens/messaging.js`、`frontend/src/screens/profile.js`、`frontend/src/styles/components.css`、`frontend/tests/ui-component-registry.test.mjs` → nginx 只读挂载目录，同步即生效。

部署后探针（日志：`artifacts/2026-08-29/red-packet-optimization/deploy-20260829T154052Z.log`）：

- 全部容器 healthy：business-api（重建后 Up, healthy）、business-worker、gateway、postgres、redis、synapse、element、mailpit、coturn、matrix-bot。
- 迁移：`0030_app_settings (head)`。
- `GET /api/v1/health/live` → `{"ok":true,"service":"畅聊 Business API"}`。
- `POST /api/v1/auth/login`（空 body）→ 422 VALIDATION_ERROR（校验链路正常）。
- `https://admin.liuhetong888.com/`（Host 探针 9443）→ 200，`<title>ChatFlow 畅聊 · 管理后台</title>`；线上 `profile.js` 红包引用数 = 0；`screens.js` → 200。

回滚方式：恢复 `backups/20260829T154052Z/` 中对应文件后重建 business-api 容器（`docker compose -f docker-compose.yml -f docker-compose.production.yml up -d --build business-api`）。

## 5. 遗留事项（非阻塞）

- 红包拆开/领取流程暂无自动化测试覆盖（可选补充）。
- 转账收款人 Cupertino 弹窗样式建议人工过目一次。
