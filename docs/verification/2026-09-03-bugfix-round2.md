# 2026-09-03 BUG 修复第二轮：会话房间共享 + 后台/锁屏通知

## BUG 1 会话房间不一致（双方各建各房）

### 根因
- Canonical 登记端点（迁移 0035）未部署生产：双方首次互开各自
  `startDirectChat` 建房，无任何去重点。
- 客户端采用对端规范房间时不补写 `m.direct`，DM 语义缺失。

### 修复
1. **生产后端部署**（2026-09-03）：`app/api/friendship.py`、
   `app/modules/friendship/{models,service}.py`、
   `app/modules/identity/profile.py`、`migrations/versions/0035_direct_conversations.py`
   同步至 `/opt/starchat/services/business-api/`；
   `docker compose build business-api && up -d`。
2. `_openCanonicalDirectRoom` 补写 `m.direct`（对端建的房间我方缺失时），
   失败不阻断；打开后房间具备 DM 语义（不再渲染成"群聊（2）"）。

### 验证
| 项 | 结果 |
| --- | --- |
| alembic 0034 → 0035 | 容器日志确认；`direct_conversations` 表在位 |
| `/api/v1/health/live` | 200（healthy） |
| `/users/lookup`、`/direct-conversations` 未登录 | 401（在位） |
| 真机「发消息」→ canonical 落库 | pair(0462589a,845c86b3) → `!vvlRlCSNwHGuHHJtPY`（复用修复后原房间，未新建） |
| 回滚备份 | `/opt/starchat/backups/business-api-20260903-pre0035/` + 旧镜像 digest `8eb74808a365` |

## BUG 2 后台/锁屏无通知（来电铃声/消息弹窗/提示音）

### 根因
通知管线本身完整（策略引擎后台发系统通知、渠道带声、来电 full-screen
intent + 应用内铃声循环），但 Android 后台进程数分钟内被冻结/查杀，
Matrix 同步长连接中断——事件根本到不了通知管线。

### 修复
- `SyncKeepAliveService`：登录会话期间常驻 **dataSync 前台服务**
  （渠道 `chatflow_sync`、通知 41003"畅聊消息服务运行中"），保活同步；
  AppHome 启动/退出登录停止/回前台幂等补启。
- Manifest：`FOREGROUND_SERVICE_DATA_SYNC` + 服务类型
  `dataSync|microphone|camera`。
- 消息通知锁屏可见性 `public`（内容已按 previewPrivacy 裁剪）。

### 验证（Mi 6，Android 9）
| 项 | 结果 |
| --- | --- |
| 前台服务 | `dumpsys activity services`：ForegroundService 运行；常驻通知 41003 在 `dumpsys notification` |
| 息屏注入对方消息（synapse 直连以对端身份发送） | 锁屏显示「畅聊 · 这个小鸿：后台锁屏通知验证消息 20260903」 |
| 证据截图 | `artifacts/2026-09-03/bug2-lockscreen-notification.png` |
| 渠道声音 | `chatflow_messages` 渠道 `res/raw/chatflow_message.ogg` + 震动（dumpsys 渠道定义） |
| 测试后清理 | 临时 access token 已从 synapse 删除 |

### 已知边界
- Android 14+ dataSync 每日约 6h 配额；MIUI 需自启动 + 省电无限制；
  用户划掉最近任务/深度清理后服务停止——该场景依赖推送通道
  （FCM/厂商推送，决策仍挂起）。
- 来电铃声：机制与消息同源（同步保活→来电信令可达→应用内铃声循环），
  双机来电验收待用户执行。

## 门禁
flutter analyze 0；flutter test 620 通过（新增 sync_keepalive 5 用例）；
backend business_api 258 通过 1 跳过（本轮后端仅部署既有代码）。
