# 2026-09-17 群聊转账/专属红包第三方展示、红包总额可见性、好友资料昵称

用户报障三项（2026-09-17 +08）。全部按 `docs/runbooks/mobile-delivery-workflow.md` 流程修复：
先定位根因、失败用例先行、最小修复、定向与全量门禁、再构建与发布。

## 1. 根因

| ID | 现象 | 根因 |
| --- | --- | --- |
| A1 | 群聊里非收款人看到转账卡片：「加载状态失败，请重试」+「对方转给你」，下方间歇性绿色「重试」 | 业务 API `GET /chat-transfers/{id}` 对非收发双方返回 404 `CHAT_TRANSFER_NOT_FOUND`（`transfer is not visible to this user`）。`FinanceCardStore` 把 403/404 之外的错误一律记为 `加载状态失败，请重试`，`FinanceMessageCard` 据此渲染可点的「重试」；卡片每 15s 轮询重取，于是重试文案间歇出现。转账引用消息里本来**没有**收款人信息，所以客户端也拿不到「转给谁」。 |
| A2 | 群聊里非指定成员看到专属红包卡片：「无权查看该状态」，下方间歇性「重试」 | 业务 API `GET /red-packets/{id}` 对专属红包的非收发双方返回 403 `RED_PACKET_FORBIDDEN`；store 把它映射成 `无权查看该状态` 并同样渲染「重试」+ 轮询。红包引用消息里没有类型/指定对象信息。 |
| A3 | 领取详情页对未领取用户显示「null 点钻」 | `red_packet_claim_detail_page.dart` 的 hero 区直接 `'${detail['total']}'` 插值。服务端 `RedPacketService.detail` 对非发起方返回 `total=None`（注释即「仅发起方可见」），Dart 把 null 渲染成字符串 `null` →「null 点钻」。 |
| A4 | 好友资料页「昵称：」行显示的是好友备注 | `ProfileIdentityCard` 的该行插值 `remark`；备注已经作为标题（`displayName = remark ?? nickname`）展示，等于把备注冒充昵称。 |

## 2. 修复

### 2.1 客户端：把「无权查看」当只读卡片，而不是加载失败

- `FinanceCardState` 新增 `restricted`：`GET` 明细返回 **403/404** 时置位（不再是 `error`），
  `terminal` 为真 → 停止 15s 轮询；`_ensureRequest` 对受限卡片不再发请求。
  其他失败（网络/序列化等）仍保留 `加载状态失败，请重试` 与手动「重试」。
- `FinanceMessageCard`：受限卡片渲染业务文案，`onTap` 关闭；
  转账卡片金额取会话消息里的 `transfer_amount`（金额本来就发给了整个房间），
  底部左侧改「转账」、右侧不臆造状态；红包卡片标签用专属文案。
- `finance_message_presentation.dart` 新增纯函数（可单测、隐私边界清晰）：
  - `counterpartyDisplayName(remark, nickname, roomDisplayName)`：**本机**备注 → 昵称 → 房间显示名；
  - `transferCounterpartyLabel` → 「转给xx」/「转账」；
  - `exclusiveRedPacketLabel` → 「给xxx的专属红包」/「专属红包」/「领取红包」。

### 2.2 客户端 + 消息格式：把「收款对象」放进房间消息（只放账号标识）

群聊转账与专属红包在服务端对第三方是不可见的，客户端只能从会话消息获知对象。因此发送时在
E2EE 房间消息里追加**账号标识**（不含任何人的备注）：

| 消息类型 | 新增字段 |
| --- | --- |
| `com.changliao.transfer` | `transfer_receiver_id`（业务 userId）、`transfer_receiver_matrix_id` |
| `com.changliao.red_packet` | `red_packet_mode`（EQUAL/RANDOM/EXCLUSIVE）、`red_packet_recipient_id`、`red_packet_recipient_matrix_id` |

链路：`ChatTransferSheet`/`ChatRedPacketSheet` → controller（state 保留对象，`retryShare` 复用）
→ `sendReference(..., receiverId/recipientId, ...)` → `MatrixRoomTimelineAdapter`
→ `RoomTimelineCapability` → `MatrixSdkE2eeClient` 事件内容；接收侧 `toViewModel` 投影回
`RoomMessageViewModel`，`RoomPage._financeCounterpartyName` 只用**当前账号**的
`contactsByMatrixId` 解析（备注 → 昵称 → 房间显示名）。

隐私：消息里只有 Matrix/业务账号标识；备注始终只在各自设备上解析，任何人看不到他人的备注。

### 2.3 红包总点钻：客户端不渲染空值 + 服务端按规则返回

- 客户端 `redPacketVisibleTotal(detail)`：`total` 为 null/空/字符串 `null` 时不渲染金额行，
  记录列表头也同步隐藏「共 x/y 点钻」。
- 服务端 `RedPacketService.detail` 的 `total_visible`：
  **发起方**始终可见；**其他有权查看者**仅在 `COMPLETED`、`EXPIRED`，或
  `status=OPEN` 但 `expires_at` 已过（worker 尚未结算）时可见；其余返回 `None`。
  这是读取投影的可见性调整，不改分配公式、账本分录、钱包状态机，也没有迁移或开关。

### 2.4 好友资料页昵称

`ProfileIdentityCard` 的「昵称：」行改为联系人**昵称**（优先取 `identityCache` 的最新投影），
仅当备注存在且与昵称不同才显示该行；备注仍作为标题。

## 3. 验证

### 3.1 本地门禁

| 命令 | 结果 |
| --- | --- |
| `flutter test`（全量） | 退出码 0，**2712 通过 / 0 失败**（改动前 2699）。日志 `artifacts/2026-09-17/flutter-full-redpacket-profile.txt` |
| `flutter analyze` | 退出码 0，`No issues found!` |
| 定向（finance/redpacket/transfer/contacts/matrix 相关） | 255 通过 / 0 失败 |
| `pytest tests/business_api -q` | 退出码 0，**1812 通过 / 58 跳过**（866.08s）。日志 `artifacts/2026-09-17/pytest-business-api-full.txt` |
| `pytest tests/business_api/redpacket -q` | 21 通过 |

新增/更新的关键用例：

- `finance_card_store_test`：403 与 404 均置 `restricted`、无 `error`、`terminal`、5 分钟内不再请求；
  非访问类失败仍保留可重试错误。
- `finance_message_card_test`：群聊第三方转账显示「转给张三」+ 金额，无「加载状态失败」/「对方转给你」/
  「重试」/「待收款」，且不可点击；专属红包显示「给李四的专属红包」，无「无权查看该状态」/「重试」；
  无名字时中性显示「专属红包」。
- `finance_message_presentation_test`：文案与展示名优先级。
- `matrix_room_timeline_adapter_test`：发送的转账/红包事件携带收款标识（无对象时不写空字段），
  入站事件投影回模型。
- `chat_transfer_sheet_test` / `chat_red_packet_sheet_test`：群聊选择群成员后引用消息带上
  matrix/业务标识。
- `red_packet_claim_detail_page_test`：`total=null` 时 hero 不渲染金额（无「null」文本）、
  记录头不显示「共 …点钻」，`total` 存在时正常显示。
- `test_redpacket_api.py::test_red_packet_total_visible_to_sender_and_after_completion_or_expiry`：
  发起方可见、进行中对成员为 null、领完（COMPLETED）可见、过期（expires_at 已过）可见。
- `contact_flow_test` / `contact_profile_selector_test`：昵称行显示昵称（Alice / Newer nickname），
  不再显示备注。

### 3.2 变异探针（证明新用例能抓住原缺陷，随后复原）

| 变异 | 结果 |
| --- | --- |
| `_viewRestricted` 恒为 false | 3 个受限卡片用例失败（`转给xx`/`给xxx的专属红包`/中性文案） |
| 昵称行改回 `remarkText` | 联系人资料用例失败（找不到「昵称：Alice」） |
| 领取详情 `?? 'null'`（还原旧渲染） | 「in-progress packet hides the total」失败（仍渲染总额键） |
| 服务端 `total_visible` 改回「仅发起方」 | `test_red_packet_total_visible_...` 失败（COMPLETED 时 total=None） |

### 3.3 生产 API 候选演练（内存 SQLite，不接触生产库）

`rehearsal.py` 与 API 测试同源断言，`docker run` 在镜像内执行：

| 镜像 | 结果 |
| --- | --- |
| 基线 `sha256:e61c6152…e828c3` | 按预期**失败**：COMPLETED 红包对非发起方仍返回 `total=None` |
| 候选 `starchat-business-api:redpacket-total-20260917`（`sha256:be11636c…`） | `REHEARSAL_OK red_packet_total_visibility module=/opt/business-api/app/modules/redpacket/service.py` |

演练先断言「被导入的模块就是生产进程使用的那一份」——镜像内同时存在
`/opt/business-api/app/…` 与 `site-packages/app/…` 两份副本（后者是更旧的快照），
只断言 import 成功会得到假绿（首次演练即撞上，见 `docs/adr/0071` 的同类教训）。

### 3.4 生产切换与切换后检查（2026-09-17 00:34 +08）

| 项 | 结果 |
| --- | --- |
| 前态 | 镜像 `sha256:e61c6152…e828c3`，容器 `starchat-business-api-1`，健康，alembic head `0067_wallet_owner_transfers` |
| 候选构建 | 基于在线镜像 `FROM sha256:e61c6152…` + 单文件 `COPY app/modules/redpacket/service.py`（`Dockerfile.api`） |
| 切换 | `docker compose --project-directory /opt/starchat -p starchat -f <adr0071/frozen-api.json> -f <本释放/api-release.json> up -d --no-deps business-api` |
| 容器身份 | `sha256:be11636c878b…` / `starchat-business-api:redpacket-total-20260917` / running+healthy |
| 部署文件 | `/opt/business-api/app/modules/redpacket/service.py` = `888237f2…137877d`（与候选一致）；导入路径即该文件；`total_visible` 标记在位 |
| 配置一致性 | 环境变量 **61/61 键一致**（含 `BUSINESS_WALLET_OWNER_TRANSFERS_ENABLED=true`）、3 个挂载一致（含 2 个只读）、端口绑定 `127.0.0.1:8082`、restart 策略一致 |
| 应用级配置 | 容器内 `Settings()`：`wallet_owner_transfers_enabled=True`、`wallet_real_mode=manual_tron` |
| 健康与鉴权 | `/api/v1/health/live` `{"ok":true,…}`；`/health/ready` 200；`/red-packets/limits`、`/red-packets/{id}` 未登录 401 |
| 迁移 | 未变（`0067_wallet_owner_transfers (head)`，本变更无迁移） |
| 其他容器 | `docker ps` 对比仅 `starchat-business-api-1` 重启，其余容器未变 |
| 日志 | 切换后 5 分钟无 error/exception/traceback 行 |
| 公网（jumper SOCKS + TLS 校验） | `https://liuhetong888.com/api/v1/health/live` 200 JSON（`ssl_verify=0`）；未登录 `limits=401`、`detail=401` |

### 3.5 返工记录（必须告知后续操作者）

首次切换误用 `/opt/starchat/docker-compose.yml` + 自建覆盖文件，导致容器**丢失 30 个环境键**
（全部 `BUSINESS_WALLET_*`，含 real mode、TOTP 加密密钥、TRONGRID key、提现/兑换/人工修复开关等）、
丢失 2 个只读挂载（tron-watch 数据目录与 handover 记录文件），端口绑定从 `127.0.0.1:8082` 变为
`0.0.0.0:8082`。原因：`/opt/starchat/services/business-api/` 这份源码树是过期的（文件名下该文件
10959 字节，在线镜像内是 15067 字节），生产容器一直由上一版释放目录的 `frozen-api.json` 渲染切换。
已在同一次任务内改用 `frozen-api.json` + 覆盖文件重切，并逐项复核恢复（见 3.4 配置一致性）。
自建的 `docker-compose.redpacket-total-20260917.yml` 已从服务器删除，回退/切换只使用
`/opt/starchat/releases/redpacket-total-20260917/{api-release.json,api-rollback.json}`。

## 4. 未执行项与限制

- 未构建 iOS；未做正式发布（2124 为 debug 真机测试包）。
- 未使用生产账号伪造会话验证响应体；生产侧证据为候选演练 + 未登录 401 + 健康/配置核对，
  真机功能由用户验收。
- **旧消息限制**：收款对象标识是本次新增的消息字段，只有 2124 起发送的转账/专属红包消息携带。
  2123 及更早发送、已在房间里的旧消息无法得知收款人，此时卡片显示中性文案（「转账」/「专属红包」），
  仍然不再出现错误文案与「重试」。如需让旧消息也显示「转给xx」/「给xxx的专属红包」，
  需在业务 API 为群成员返回脱敏的专属对象（新字段或端点），属新范围。
