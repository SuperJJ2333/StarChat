# R6 文本发送跨房公平调度

## 恢复入口与授权

- 用户本轮已授权继续修复；执行主工作树 `docs/superpowers/plans/2026-10-11-im-reliability-remediation.md` 的 R6。此子任务只实现、测试及提交，不部署。
- 工作树：`C:/Users/Administrator/.codex/worktrees/im-send-scheduler/StarChat`；基线 `5c83a08a09b985146bc507a1608cb2153d361e48`。
- 文件所有权：发送调度器及两项 outbox 测试；主任务随后授权扩展 `outbox_room_sender_registry.dart`、`room_timeline_controller.dart` 的真实结算查询、`room_page.dart` 尾部适配器及 `outbox_send_flow_test.dart`。
- 当前：实现及相关门禁通过；等待规格审查后质量审查和主任务集成。共享全量、双端构建及真实设备验收由主任务在最终候选上统一执行。
- 最后源码冻结：2026-10-11 11:14:41+08:00；逐文件 SHA256、基线 Git blob 与依赖锁见 [输入身份](artifacts/2026-10-11/im-send-scheduler/input-hashes.json)。

## 根因与修改

旧调度器先等待未绑定会话解析，再逐房等待发送，健康房间因此等待慢房间的 30 秒预算。页面发送 Future 又会在 20 秒 UI 观察预算结束，而底层 SDK 请求仍在途；仅检查行 ID 或 Future 返回不能保证同房串行。

调度器现在每轮每房只选创建顺序中的队首行，最多占用两个房间位置，以轮转队列分配空位。未绑定解析有独立的两个真实在途位置；超时观察器不归还其容量。租约每轮释放，下一轮重新检查当前页面发送句柄和权限。429 的持久化期限继续阻止该房后续行越过队首；原 txid、claim CAS、创建时间和服务端重试预算未改变。

可选 `OutboxTransportSettlement` 将页面的实际 `_dispatchSettled` Future 接到调度器。控制器保留的是 UI `.timeout` 之前的 Future，页面适配器捕获原控制器所有权，因此 UI 超时、删除本地行和页面退出均不能提前归还房间位置。传统发送器继续以 durable `sending` 作为保守屏障；读取失败不当作行删除。前台已经在途的 durable claim 完成后，会唤醒被屏障挡住的后台队列。

没有改 Matrix 客户端、媒体实现、AppHome、pubspec 或依赖锁；E2EE、业务/财务权威与账户门禁保持。

## 验收与证据

| 场景 | 结果 | 证据 |
| --- | --- | --- |
| A 三条，第一条一直 pending，B 在测试时钟 200ms 内进入传输 | 先 RED，后 GREEN；A 真正在途仍一条，迟到 ACK 后按原顺序继续 | `red.log`、`focused-green.log` |
| 多房轮转与两条真实传输上限 | GREEN；A 释放后 C 先于 A 第二条，观察超时后仍不超过二条 | `focused-green.log` |
| 四个 unbound 解析 pending 不挡 bound 房间 | 先 RED，后 GREEN；解析最多二个，超时/重复 drain 不重复解析 | `red.log`、`focused-green.log` |
| 真实控制器 UI 超时后删除 outbox 行 | 先 RED，后 GREEN；删除不提前派发第二条，真实 ACK 后继续，气泡不重复 | `red-ui-delete.log`、`focused-green.log` |
| 账号/页面 teardown 后迟到结果 | GREEN；旧真实 Future 保留到结算，不启动后续发送 | `focused-green.log` |
| 前台先发送，ACK 后恢复后台同房队列 | 先 RED，后 GREEN；不需要新的网络恢复边沿 | `red-foreground-ack.log`、`focused-green.log` |
| 429、撤权、重连、迟到 ACK、取消、存储失败、重启恢复 | 原完整文件与新增顺序/取消用例通过 | `focused-green.log` |
| 静态分析、格式和 diff | 7 个修改文件 analyze 无问题；format、`git diff --check` 通过 | `analyze.log` |

以上日志均位于 `docs/verification/artifacts/2026-10-11/im-send-scheduler/`。测试夹具仅合成身份和消息，不调用生产服务。

## 命令与运行身份

PowerShell 7.6.5，Windows 10.0.19045；每次会话设置 UTF-8 无 BOM console/pipeline 和 Python UTF-8。Flutter 3.44.9（`6b182d2c75`），Dart 3.12.2，SDK 来自本地 `android/local.properties` 的 `flutter.sdk=C:/src/flutter`。

首次离线 pub get 受已有镜像环境影响试图更改锁文件，已恢复本任务产生的变更。随后仅进程级设置 `PUB_HOSTED_URL=https://pub.dev`，`flutter pub get --offline --enforce-lockfile` exit 0；原锁 SHA256 `12ae67427fe7b17a65aa929773940cfef1ce97be4fe5240a925a373c771f191e` 保持。未改全局 Pub 缓存。

在 `apps/mobile_flutter` 运行：

```text
flutter test --no-pub test/core/outbox/message_send_scheduler_test.dart test/core/outbox/unbound_resolution_retry_test.dart --name 'pending room|room turns|pending resolution does' --reporter expanded
```

基线 RED：exit 1，3 个预期行为失败。另两个真实控制器 RED 分别以 `--name 'scheduler keeps true controller ownership'` 和 `--name 'foreground ACK wakes'` 运行 `outbox_send_flow_test.dart`，均 exit 1，失败原因分别为同房过早派发和 ACK 后漏唤醒。

最终相关门禁：

```text
flutter test --no-pub test/core/outbox test/features/matrix/outbox_send_flow_test.dart test/features/matrix/room_timeline_controller_test.dart test/features/matrix/automatic_retry_order_test.dart test/features/matrix/offline_send_state_test.dart test/features/matrix/canonical_send_guard_test.dart test/features/matrix/room_send_identity_regression_test.dart test/features/matrix/pending_conversation_outbox_test.dart --reporter expanded
```

exit 0，**194 PASS**，无跳过。范围 analyze 7 个修改 Dart 文件 exit 0，无问题。旧租约失败用例现在明确创建顺序并提供两次租约，验证每轮都释放资源，避免同毫秒 UUID 排序决定哪个错误先出现。

`scripts/verify.ps1` 已预检：此隔离工作树没有 `.env`，其 render-only 步骤需要配置；不导入生产秘密执行该流程。按主任务及 mobile-delivery-workflow 的最终候选规则，本子任务不重复执行共享全量 Flutter/跨域验证，也不宣称完整 verify exit 0。SDK 网络、两端真机、弱网 p95 和双端收端解密验证仍待主任务完成；本报告的 200ms 为注入测试时钟的调度准入断言。

## 阶段计时与下一步

| 阶段 | 已知观察时间（+08:00） | 结果 |
| --- | --- | --- |
| 工作树、上下文及 SDK 基线 | 10:57:39 | 基线与工具确认；更早精确起始未知 |
| 初版实现及专项回归 | 11:05:47 | 跨房与解析行为转绿，补 UI 所有权接口 |
| 第一轮扩大门禁和输入冻结 | 11:12:16 | 193 PASS；进一步发现前台 ACK 唤醒缺口 |
| ACK 唤醒 RED→GREEN 与候选再冻结 | 11:14:41 | 194 PASS；input-hashes 更新 |

主动/工具时长未连续计时，精确分解未知；最终测试日志报告执行 13 秒，不等于全部任务墙钟。未运行部署、构建或外部设备操作。

下一步：主任务先做 SPEC、再做 QUALITY/SECURITY 审查，按本次输入身份合入最终共享候选，执行统一门禁。回退仅回退调度/所有权接线提交，不删除或重建任何 outbox 数据。

## 审查补充：前台删行与真实页面适配器

首个候选提交为 `d72b8a12ab8028984c5b0a0c3d9e9ca57bb9004b`。主任务提出一个待验证边界：前台已持有真实传输，用户删除 durable 行后，同房后台队列是否仍受屏障保护。以真实控制器分别覆盖调度器删除前已扫描、删除前未扫描两种时序，两个用例在首候选均 RED，日志为 `red-foreground-delete.log`。失败均为旧 SDK Future 未结算时第二个 txid 已派发。

最小补充接口 `pendingRoomTransportSettlement` 查询控制器尚未结算的原始 `_dispatchSettled` 集合；调度器捕获外部真实所有权，行删除和 30 秒观察窗口不释放占用。真实结算后唤醒原轮转队列。主任务授权将 RoomPage 尾部适配器抽成 `lib/features/matrix/room_outbox_sender.dart`，页面仍提供原权限和生命周期条件，测试直接使用生产适配器。

新增适配器用例断言：`send()` 返回后、第一次 pump 前，已捕获控制器原始 Future；UI 超时返回错误后清空页面 controller 并 dispose、删除行、再过 31 秒，该 Future 仍未完成且 room 查询仍有占用；只有完成模拟 SDK 原请求后才清空。原账号 teardown、429、迟到 ACK、取消和排序回归继续通过。

最终补充冻结为 2026-10-11 11:32+08:00，输入见 [followup-input-hashes.json](artifacts/2026-10-11/im-send-scheduler/followup-input-hashes.json)。同一完整专项命令 **197 PASS**，exit 0，日志 `focused-green-followup.log`；8 个 Dart 文件范围 analyze exit 0、无问题，日志 `analyze-followup.log`；format 与 `git diff --check` 通过。旧日志及旧输入清单保持用于各轮 RED/GREEN 追踪。共享全量、双端与生产行为的验收边界仍按上文由主任务完成。

## 审查补充：真实注册表离页组合

第二候选 `d7aafb99a737d3e381636f314343b2019a30e8f6` 的生产适配器测试仍固定返回 sender，未覆盖真实 `OutboxRoomSenderRegistry.senderFor` 在 `canSend=false` 和页面 unregister 后返回 null 的行为。主任务提出该组合边界后，使用真实 registry、生产 adapter、控制器和后台 lease 复现：前台 SDK 未结算，用户删除 durable 行并离页，调度器首次扫描时错误派发第二条。两个预期失败记录在 `red-registry-page-loss.log`。

注册表现在将可发送句柄与真实 settlement 生命周期分开：活动句柄查询不依赖 `canSend`；unregister、页面替换和 clear 捕获实际 Future，仅在该 Future 结算后移除。调度器新增可选 `roomSettlements` 回调，接收所有房间的真实占用快照；无 durable 行的旧前台房间也计入跨房二个在途上限。回调的错误或成功结算均仅释放对应 Future 的占用；旧页面注销不移除新页面句柄。保留对象为原实际 Future 和房间标识，不保存消息正文。

实际回归覆盖 inactive / unregister / replace / clear 四种首次扫描前离页时序，以及“已删除 A 行的真实请求 + B pending + C queued”仍只启动两个真实传输，A ACK 后再轮到 C。相同专项命令 **202 PASS**，exit 0；范围 analyze 8 文件无问题，format 和 diff check 通过。证据 `focused-green-registry.log`、`analyze-registry.log`；11:40+08:00 输入冻结见 [registry-input-hashes.json](artifacts/2026-10-11/im-send-scheduler/registry-input-hashes.json)。

**集成依赖**：本子任务未修改当前由 R5 owner 占有的 `app_home.dart`。必须在 `MessageSendScheduler` 构造处增加 `roomSettlements: OutboxRoomSenderRegistry.shared.pendingRoomTransportSettlements`，已把 [精确单参数补丁](artifacts/2026-10-11/im-send-scheduler/app-home-settlement-callback.patch) 交给 `/root/review_r1_r2`，在本树 `git apply --check` 通过；由该 owner 应用并单独提交、主任务最终候选验证。该接线合入前，本报告不宣称生产 AppHome 组合已闭环。
