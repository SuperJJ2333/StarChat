# 任务记录：群聊转账/专属红包第三方展示、红包总额可见性、好友资料昵称（Debug 2124）

## 恢复入口

- 目标、用户授权来源及边界：用户 2026-09-17 报障三项并要求「修复完请你推送 debug 版给我测试」。
  ① 群聊里非收款人/非指定成员查看转账与专属红包时出现「加载状态失败，请重试」/「无权查看该状态」与间歇性
  绿色「重试」，应分别显示「转给xx」「给xxx的专属红包」（xx 为**查看者本人**的备注或昵称，不得泄露他人备注）；
  ② 红包「看看大家的手气」→ 领取详情页对未领取用户显示「null 点钻」，应去除，且总点钻仅对发红包的人
  或红包已领完/已过期时展示；③ 好友资料页「昵称」行错误显示好友备注，应显示昵称。
  边界（用户在被问及时明确选择）：② 客户端 + 业务 API 一起修并部署生产 API；群聊第三方转账卡片显示金额。
  不做正式发布、不构建 iOS、不改钱包/账本/Matrix 服务端。
- 关联计划/ADR：无独立计划或 ADR（缺陷修复；红包 total 可见性是读取投影的可见性策略调整，
  未改分配公式、账本、钱包状态机或迁移）。
  验证记录 [2026-09-17-redpacket-transfer-profile](../../verification/2026-09-17-redpacket-transfer-profile.md)；
  2124 交付记录 [2026-09-17-redpacket-profile-2124-mi6](../../verification/2026-09-17-redpacket-profile-2124-mi6.md)。
- 当前状态：实现、本地验证、生产 API 部署完成；2124 debug 包已安装 Mi 6；**待用户真机验收**
- 负责人、工作树、文件所有权、源码commit：主工作树 `D:\pythonProject\outsource\StarChat`
  （分支 main；本任务源码提交 `35090fd0`，基线 `5d43ce34`，未 push）。拥有：
  `core/business_api_client` 无关；拥有 `features/finance/*`、`ui/finance/wechat_transfer_card.dart`、
  `features/matrix/{room_page,room_timeline_controller,matrix_room_timeline_adapter,matrix_e2ee_client,
  chat_red_packet_controller,chat_red_packet_adapters,chat_red_packet_sheet}.dart`、
  `features/transfer/*`、`features/redpacket/red_packet_claim_detail_page.dart`、
  `features/contacts/contact_profile_sections.dart`、`services/business-api/app/modules/redpacket/service.py`
  及对应测试。
- 最后更新时间（含时区）：2026-09-17 00:5x +08（Asia/Hong_Kong）
- 下一条具体操作、必要输入、阻断的验收ID：用户按 2124 交付记录第 4 节真机验收 A1–A3；
  **A1/A2 需用 2124 新发送的转账/专属红包**（旧消息不含收款对象标识，见「交接与回退」）。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | 群聊非收款人看到的转账卡片：显示金额 +「转给xx」，无「加载状态失败，请重试」、无「对方转给你」、无「重试」 | `FinanceCardState.restricted`（403/404 不再当错误）+ `transferCounterpartyLabel`（本机备注→昵称→房间显示名）+ `WeChatTransferCard.footerLabel/statusLabel` + 消息内 `transfer_receiver_id/_matrix_id` | `finance_card_store_test`（403/404 受限、非访问失败仍可重试、受限不轮询）；`finance_message_card_test` 转账受限用例；`finance_message_presentation_test`；`matrix_room_timeline_adapter_test`（发送/投影携带收款标识）；`chat_transfer_sheet_test`/`chat_transfer_controller_test` | 2124 debug 已装 Mi 6；API 无改动 | 待真机 |
| A2 | 群聊非指定成员看到的专属红包卡片：显示「给xxx的专属红包」，无「无权查看该状态」、无「重试」 | 同上 + `exclusiveRedPacketLabel` + 消息内 `red_packet_mode/_recipient_id/_recipient_matrix_id` | `finance_message_card_test` 专属红包受限用例（含无名字时中性「专属红包」）；`chat_red_packet_sheet_test`/`chat_red_packet_controller_test`；`matrix_room_timeline_adapter_test` | 同上 | 待真机 |
| A3 | 领取详情页：未领取用户不再看到「null 点钻」；总额仅对发起方或领完/过期可见 | 客户端 `redPacketVisibleTotal`（null 时不渲染金额行）；API `RedPacketService.detail` 的 `total_visible`（发起方 / COMPLETED / EXPIRED / expires_at 已过） | `red_packet_claim_detail_page_test`（null 隐藏、已完成展示）；`tests/business_api/redpacket/test_redpacket_api.py::test_red_packet_total_visible_to_sender_and_after_completion_or_expiry`；服务端候选镜像演练 | 客户端 2124 + **生产 API `starchat-business-api:redpacket-total-20260917`（2026-09-17 00:34 +08 切换）** | 待真机 |
| A4 | 好友资料页「昵称」行显示对方昵称而非备注 | `ProfileIdentityCard` 改用联系人昵称（备注仅作标题） | `contact_flow_test`（昵称 Alice / 备注 产品小艾）、`contact_profile_selector_test` | 2124 debug | 待真机 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Android Debug（仅 Mi 6 真机） | 0.3.92-debug / 2124 | `35090fd0` | `com.liuhetong.mobile`，固定身份 `75b31c66…ba61fff` | `artifacts/2026-09-17/android-0.3.92-debug-2124/ChatFlow-0.3.92-debug-2124-arm64-rebuilt.apk`，SHA256 `8ff43006…98c52d`（源码中间包 `91185032…56ad331`） | 2026-09-17 00:35:11 +08 覆盖安装成功，firstInstallTime 未变；**未做正式发布** |
| 业务 API（生产） | `starchat-business-api:redpacket-total-20260917` digest `sha256:be11636c878b…c8aeb5`（基于在线镜像 `sha256:e61c6152…e828c3` 单文件叠加） | `35090fd0`（仅 `services/business-api/app/modules/redpacket/service.py`） | 容器 `starchat-business-api-1` | 释放目录 `/opt/starchat/releases/redpacket-total-20260917/`（0700）：`payload-api/…/service.py` SHA256 `888237f2…137877d`、`api-release.json`、`api-rollback.json`、`Dockerfile.api`、`rehearsal.py`、`backup/` | 2026-09-17 00:34:14 +08 切换完成；健康 200、未授权 401、alembic head 0067 未变 |
| iOS | 未构建 | — | — | — | 未发布 |

测试记录：

- `flutter test`（全量，改动后）→ 退出码 0，**2712 通过 / 0 失败**（改动前基线 2699）。
  日志 `artifacts/2026-09-17/flutter-full-redpacket-profile.txt`。
- `flutter analyze`（全量）→ 退出码 0，`No issues found!`。
- 定向：`test/features/finance`、`test/features/redpacket`、`test/features/transfer`、
  `test/features/contacts`、`test/features/matrix/{chat_red_packet_sheet,matrix_room_timeline_adapter,
  room_timeline_controller}` → 255 通过 / 0 失败。
- 变异探针（证明新用例能捕获原缺陷，改动后复原）：
  `_viewRestricted` 置否 → 3 个受限卡片用例失败；`昵称：$nicknameText` 改回备注 → 联系人用例失败；
  领取详情 `?? 'null'` → 「null 点钻」用例失败；API `total_visible` 改回仅发起方 →
  `test_red_packet_total_visible_...` 失败。
- 服务端：`pytest tests/business_api -q` → 退出码 0，**1812 通过 / 58 跳过**（866.08s），
  日志 `artifacts/2026-09-17/pytest-business-api-full.txt`；
  `tests/business_api/redpacket` 定向 21 通过。
- 候选镜像演练：`rehearsal.py`（内存 SQLite + ASGI，无生产库）——基线镜像按预期失败
  （COMPLETED 红包对非发起方 total=None），候选镜像 `REHEARSAL_OK`，且断言被导入模块为
  `/opt/business-api/app/modules/redpacket/service.py`。
- 2124 重建验证：清单语义一致、原生/Flutter 资产差异 0、smali 类差异 0（27313/27313）、
  ZIP 条目 948/951；`zipalign -c -P 16 4`、`aapt`（2124 / 0.3.92-debug / debuggable / arm64-v8a）、
  `apksigner verify`（固定证书）通过。
- 工具版本 Flutter 3.44.9 / Dart 3.12.2 / Apktool 2.12.1 / build-tools 36.0.0 / JDK 17.0.20.8；
  OS Windows 10 Pro 19045；设备 Xiaomi MI 6（`sagit`，adb `cbd0156b`），Android 9。
- 未执行项：未构建 iOS；未做正式发布；未用生产账号伪造会话（只有 401 边界与候选演练证据）；
  旧消息（2123 及更早发送）的收款对象无法得知，未做覆盖（见「交接与回退」）。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 代码定位与基线 | 2026-09-17 00:0x +08 | 00:12 | 主动 | — | 源码/历史任务记录 | — |
| 客户端 TDD 修复 | 00:12 | 00:26 | 主动 | 与全量测试并行 | 见验收台账 | — |
| 服务端 TDD 修复 | 00:26 | 00:28 | 主动 | — | pytest | — |
| 全量门禁 + analyze | 00:26 | 00:30 | 工具 | — | 2712 通过 / analyze 干净 | — |
| 2124 构建/重建验证 | 00:29 | 00:33 | 工具 | 与服务端释放并行 | 构建日志 | — |
| 生产 API 释放 | 00:31 | 00:34 | 主动+工具 | 与构建并行 | 释放目录证据 | — |
| **返工：容器配置来源** | 00:33 | 00:34 | 返工 | — | 首次误用 `docker-compose.yml`，丢失 30 个 `BUSINESS_WALLET_*` 环境键与 2 个只读挂载、端口绑定由 127.0.0.1 变 0.0.0.0；改用上一版释放的 `frozen-api.json` + 覆盖文件重切，复核 61/61 键一致 | 已在文档中记录教训 |
| Mi 6 安装与回读 | 00:35 | 00:36 | 工具 | — | 安装日志 | — |
| 文档与索引 | 00:36 | 进行中 | 主动 | — | — | — |

总墙钟：约 40 分钟（精确分段计时未逐段记录，不估成精确值）。

## 交接与回退

- 已确认根因/已排除假设：
  ① 转账/专属红包对第三方本就被业务 API 拒绝（404 `CHAT_TRANSFER_NOT_FOUND` / 403
  `RED_PACKET_FORBIDDEN`），而客户端把 403/404 当成加载失败：转账落到「加载状态失败，请重试」+「对方转给你」，
  专属红包落到「无权查看该状态」，两者都渲染可点的绿色「重试」，且每 15s 轮询刷新导致间歇性出现。
  ② 领取详情页把 `detail['total']` 直接字符串插值，非发起方 total 为 null →「null 点钻」。
  ③ `ProfileIdentityCard` 的「昵称：」行插值的是 `remark`。
  已排除：Matrix 房间成员关系、E2EE、账本/钱包状态机、红包分配公式。
- 待办及验收失败项：A1–A4 待用户真机验收。
- **已知限制（旧消息）**：收款对象标识是本任务新增的消息字段，只有 2124（及以后）发送的转账
  /专属红包消息携带。2123 及更早发送、已落在房间里的旧消息无法得知收款人，此时卡片显示中性文案
  （转账「转账」、专属红包「专属红包」），仍然没有错误文案与重试。若需覆盖旧消息，需要在业务 API
  为群成员返回脱敏的专属对象（新端点/字段），属于新范围，未在本任务实施。
- 已发布与仅候选的区别：Android 2124 为**真机 debug 测试包**，未做正式发布；业务 API 变更已**实际部署生产**
  （读取投影的可见性调整，无迁移、无开关、无账本写入）。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：
  释放目录 `/opt/starchat/releases/redpacket-total-20260917/`（0700），内含
  `backup/service.py.pre`（前态文件 SHA256 `b51d078a…1acb87`，等于仓库 HEAD blob）、
  `backup/container-image.txt`（前态镜像 `sha256:e61c6152…e828c3`）、`backup/ps-before.txt`、
  `backup/alembic-before.txt`、`api-release.json`（候选切换）、`api-rollback.json`（回退切换）。
  回退命令：
  `docker compose --project-directory /opt/starchat -p starchat -f /opt/starchat/releases/adr0071-owner-transfer-20260915/frozen-api.json -f /opt/starchat/releases/redpacket-total-20260917/api-rollback.json up -d --no-deps business-api`
  漂移检查：切换后必须复核 env 61 键、3 个挂载、`127.0.0.1:8082` 端口绑定与上一版一致。
- **教训（必须沿用）**：`/opt/starchat/services/business-api/` 这份源码树是**过期的**
  （该文件 10959 字节，与在线镜像的 15067 字节不同），绝不能用 `docker-compose.yml` 直接
  `up`/重建；生产容器一直由上一版释放目录里的 `frozen-api.json` + 覆盖文件切换，
  否则会丢环境变量/挂载/端口绑定（本任务首次切换即踩中，已在同一次任务内修正并复核）。
- 运行中CI/命令/自己创建的隧道（无凭据）：临时 SOCKS（`127.0.0.1:18945`）已关闭；
  无运行中的构建/测试任务。
- 下次恢复先检查的事实：Mi 6 上 `com.liuhetong.mobile` 是否为 2124；
  生产 `starchat-business-api-1` 是否仍为 `sha256:be11636c878b…`（或后续已批准版本），
  且 `/opt/business-api/app/modules/redpacket/service.py` 为 `888237f2…137877d`；
  仓库 `services/business-api/app/modules/redpacket/service.py` 是否仍含 `total_visible`。

