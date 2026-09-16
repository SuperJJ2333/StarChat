# 2026-09-16 iOS build 2121 仍存在 L04/L07：根因、修复与验证

源码基线 `8ef5cbac4c80b49a9ad43f54f84a01bedf8dc9c8`（工作树未提交改动，本任务只改动下列文件）。
证据时间 2026-09-16 23:10 +08。**未构建 APK/IPA、未安装真机、未部署生产**；真机验收由用户执行。

## Root Cause（2121 为什么仍然 L04/L07）

2121 的 `81bac4e8` 只修好了"挂起因 drain 超时中断"这一条链，没有处理 **device id 轮换**：

1. 服务端单设备策略把本机 `device-OLD` 吊销，本机重登时 `m.login.token` 返回 `device-NEW`。
2. `MatrixSdkE2eeClient.loginWithToken` 的保留身份路径采纳了 `device-NEW` 并调用
   `Client.init(newDeviceID:)`；SDK 立即把 `device-NEW` 写进本地库（`updateClient`）。
3. ChatFlow 自己维护的 `MatrixLocalBinding` 没有跟着迁移，于是磁盘上出现
   `库=device-NEW / binding=device-OLD`。
4. 紧接着的 `_persistLoggedInContinuity → MatrixClientFactory.continuityMetadata` 要求
   `binding.deviceId == client.deviceID`，抛 `StateError('Matrix client does not match the local binding')`
   → 登录在 `matrix_login` 阶段失败 → **L04**。
5. 失败清理 `_compensate() → matrix.suspend()` 再次读取同一 continuity，再次抛错，于是
   `suspend` 在 `_suspendClient` 之前中断：留下 `_accessRevoked=true`、`_client != null`、
   数据库仍打开的**半挂起态**。
6. 之后任何需要 `selectAccount` 的登录（本地身份为空或切换账号）都在
   `_selectAccount → resume → _readContinuityMetadata` 上重复失败 → **L07**；
   而由于 binding 只在"空库"时才被清理，本机库非空，这个失败会一直持续（2121 用户升级后
   也不自愈）。这就是"只能重登原账号、新账号必 L07"与"重登原账号仍 L04"的组合。

诊断证据（修复前真实失败输出，本次测试固化）：

```
Bad state: Matrix client does not match the local binding
  package:liuhetong_mobile/features/matrix/matrix_client_factory.dart 142:7  MatrixClientFactory.continuityMetadata
```

同时确认既有测试 `token refresh adopts a server-rotated device id instead of L04` 不充分：
它使用全新 `SecureSessionStore(MemoryStore())`，binding 为空，`continuityMetadata` 会**新建**
一份 device-NEW 的 binding，因此永远不会走进真实设备上的"binding 已存在且为 device-OLD"分支。

## Changed Files

| 文件 | 改动 |
| --- | --- |
| `apps/mobile_flutter/lib/core/matrix_local_binding.dart` | 新增 `MatrixDeviceBindingRotationRejected`（只含固定原因码，不含标识） |
| `apps/mobile_flutter/lib/core/session_store.dart` | 新增 `rotateMatrixDeviceBinding`（服务端权威轮换）与 `adoptMatrixDeviceId`（遗留态补齐），共用私有 `_rewriteBindingDeviceId`；只改写 `deviceId`，其余字段逐字保留，读改写在同一 identity 串行区内完成 |
| `apps/mobile_flutter/lib/features/matrix/matrix_client_factory.dart` | `continuityMetadata` 拆分身份锚点与 device 标签并加入权威轮换采纳；新增 `rotateDeviceBinding`；新增 `securityLogger`/`diagnosticHasher` 注入 |
| `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart` | `hasSameContinuity` 不再比较 deviceId；`loginWithToken` 在服务端证明后调用轮换迁移、调用方陈旧 device 提示不再硬失败；`suspend` 重构（`_suspendWithinLifecycle`、`_suspendedIdentity`、`MatrixSuspendedContinuity`）；`selectAccount` 合并为单一生命周期临界区并保证失败后状态一致；`clearLocalChatData`/resume 清理挂起状态；新增诊断事件 |
| `apps/mobile_flutter/lib/features/matrix/matrix_security_logger.dart` | 新增 stage（account_selection/device_rotation/continuity）、15 个事件码、`beginLifecycleOperation()`（等价 login_attempt_id）、`MatrixDiagnosticHasher` + `MatrixDiagnosticIdentity`（只能承载加盐哈希） |
| `apps/mobile_flutter/lib/main.dart` | 用 `store.diagnosticSalt()` 构造 hasher，注入 factory 与 client；注入 `rotateDeviceBinding` |
| `apps/mobile_flutter/test/features/matrix/device_rotation_login_lifecycle_test.dart` | 新增（14 个用例） |
| `apps/mobile_flutter/test/features/matrix/matrix_client_factory_test.dart` | 更新 2 个用例：device 轮换必须补齐 binding（并保留 fingerprint 拒绝分支）；挂起事件列表 |
| `docs/adr/0072-matrix-device-id-rotation-continuity.md` | 新增 ADR（提案，待批准） |

## Lifecycle Before

```
remote login on another device
→ server revokes device-OLD，本机重登返回 device-NEW
→ Client.init(newDeviceID: device-NEW) 写入本地库
→ binding 仍旧 device-OLD
→ continuityMetadata 抛错 → L04
→ _compensate → suspend → 同一个 continuity 抛错 → client 未关闭、库仍打开
→ 半挂起（_accessRevoked=true 且 _client!=null）
→ 下一次登录走 selectAccount → resume → 同样抛错 → L07（永久）
```

## Lifecycle After

```
remote login on another device
→ server revokes device-OLD，本机重登返回 device-NEW
→ token 登录已证明账号归属（user_id 与保留身份一致、device 非空）
→ rotateDeviceBinding 独立复核 client 最终身份 + binding 的
  matrixUserId / homeserver / ed25519Fingerprint
→ 原子迁移：只把 deviceId 改为 device-NEW，库代号与 Olm 指纹原样保留
→ continuityMetadata 通过（同账号、同 homeserver、同指纹、同库代号）
→ _credentialsInvalid=false、onLoginStateChanged=loggedIn
→ completeMatrixSession → sync → 进入聊天首页
（若进程在迁移前被杀：resume 时 adoptMatrixDeviceId 以同样的密码学锚点补齐，
  并记录 E2EE_DEVICE_ROTATION_BINDING_MIGRATED）
```

## Security

- `device-OLD → device-NEW` 只是服务端设备标签，不改变本地 Olm(Ed25519) 私钥、Megolm
  会话、SQLCipher 库密钥或库代号。修复没有创建新身份、没有重建 Olm 账号、没有删除任何
  聊天记录/Megolm 会话，也没有更换 SQLCipher key（测试断言 cipher 与库路径不变、
  `deletedPaths` 为空）。
- 迁移的准入条件是**密码学锚点全部逐字相同**：`matrixUserId`、`homeserver`、
  `ed25519Fingerprint`；服务端路径还要求 token 登录成功且 `user_id` 等于保留身份。
  换账号、换 homeserver、Olm 身份变化、库代号变化一律失败关闭并保留原 binding。
- 对抗性复审：能改写本地库的攻击者必然已持有 Keychain 中的库密钥；能改写 Keychain 的
  攻击者可以直接改写 binding。因此"deviceId 不参与身份比较"不提供新的攻击能力。
- 未弱化任何 E2EE 校验：SDK 的 `preserveStoreOnInvalidToken`、Olm 上传、
  `hasSameContinuity` 的指纹/代号比较、`_accessRevoked` 语义均保留。
- 关闭安全与信任分离：continuity 读取失败时 client 仍被安全关闭，但状态显式标记
  `unknown`，`_suspendedMetadata` 保持 null，后续 resume 仍然失败关闭，绝不假装已验证。
- 日志：新增事件只包含 allowlist 的 stage/outcome/event_code 与**加盐哈希**后的标识；
  测试断言原始 `@a:test`、`device-OLD/NEW`、`fingerprint-a`、access/refresh/login token
  都不出现在输出中。

## Tests

新增 `test/features/matrix/device_rotation_login_lifecycle_test.dart`（15 用例，覆盖用户列出的
Test 1-10 与集成要求）：

- 服务端轮换 + 已存在 binding：登录完成、binding 只改 deviceId、`credentialsInvalid=false`
- Olm 身份变化 → 拒绝且不改写 binding（Test 2）
- 服务端返回不同 Matrix 账号 → 拒绝（Test 3）
- `rotateDeviceBinding` 四类前置条件拒绝（previous device/账号/client 最终 device/指纹）
- 2121 遗留态（库新、binding 旧）在 resume 时自愈；若 Olm 身份不一致则安全关闭且 continuity=unknown
- `selectAccount` 切到"被旧版本轮换过"的账号库不再卡在 L07，且补齐时保留库代号与指纹
- `suspend` 在 continuity 读取失败时仍关闭 client（Test 4）
- drain 超时 + continuity 失败仍关闭 client（Test 5）
- L04 型失败后重试不再变成 L07、失败清理真正关闭 client（Test 6）
- A→B→A：各账号使用自己的库路径、SQLCipher key、binding，无删除、无 alias（Test 7/8）
- 同账号远端登录全链路（业务登录→授权→selectAccount→resume→token 登录→轮换→迁移→
  completeMatrixSession→sync）（Test 9）
- 生命周期串行：并发 suspend 不产生半开状态，随后登录仍成功（Test 10）
- 集成：`DualDomainLoginService + MatrixSdkE2eeClient + MatrixClientFactory + SecureSessionStore`
  首次登录全链路（selectAccount→resume→token 登录→matrix-session→sync）
- 诊断日志只含加盐哈希

**敏感性（变异）检查**：临时把 `continuityMetadata` 的 device 分支改回旧的"不一致即抛错"
语义后重跑该文件，只有两条"旧版本遗留态自愈"用例转红，其余 13 条保持通过；证明这两条用例
确实覆盖生产路径，而不是测试内的自造逻辑。恢复代码后重新全绿。

**既有测试为何漏掉该 BUG**：`test/core/history_continuity_flow_test.dart` 等 Core 用例使用的是
`_Matrix` 桩（只实现 `MatrixSessionGateway`/`MatrixTokenLoginGateway`），从不经过
`MatrixClientFactory.continuityMetadata` 的 device 比较，因此对生产 BUG 完全不敏感；
`matrix_client_factory_test.dart` 原有的轮换用例用空 `MemoryStore()`，binding 未预先存在，
`continuityMetadata` 会新建 binding 而绕开比较。本任务新增的文件用真实
`MatrixSdkE2eeClient + MatrixClientFactory + SecureSessionStore` 装配填上这个缺口。

命令与真实结果（Flutter 3.44.9 / Dart 3.12.2，Windows 10 Pro 19045，工作目录 `apps/mobile_flutter`）：

| 命令 | 结果 | 退出码 |
| --- | --- | --- |
| `flutter test test/features/matrix/device_rotation_login_lifecycle_test.dart` | 15 通过 / 0 失败 | 0 |
| `flutter test test/features/matrix test/features/auth test/core` | 1672 通过 / 0 失败 | 0 |
| `flutter test`（全量） | 2699 通过 / 0 失败 | 0 |
| `dart analyze <本任务 8 个文件>` | No issues found | 0 |
| `flutter analyze`（全仓） | 2 个 error，均在本任务未触及、由**并行任务**修改的 `lib/features/transfer/chat_transfer_sheet.dart:233` 与 `test/features/moments/moment_comment_composer_test.dart` | 1 |

修复前同一组用例 6/6 失败（L04、`Matrix client does not match the local binding`、
suspend 未关闭 client），失败点与上述根因逐条对应。

输入 hash（SHA256 前 16 位）：matrix_local_binding.dart `877b3d0febfea894`、
session_store.dart `c0d74f9fa9156b15`、matrix_client_factory.dart `e44c77f16e6a926e`、
matrix_e2ee_client.dart `7f8d66f6d57b063c`、matrix_security_logger.dart `ea461f8717fea1ad`、
main.dart `2ad13525e0c8b3ae`、device_rotation_login_lifecycle_test.dart `a6292a7a8a0c9bd5`、
matrix_client_factory_test.dart `82fa39b77f567287`。

## Remaining Risks

1. **未做真机验证**：本次只跑自动测试；`Client.init`、`updateClient`、iOS Keychain
   在真机上的实际行为需要用户按验收场景复测（同账号 A 已在设备 1 登录 → iPhone 重登 A）。
2. **旧的 `deviceId` 比较被放宽**：如 ADR-0072 所述，这是有意的语义修正，需要领域/质量安全
   审查人确认；ADR 状态为"提案，待批准"。
3. **Olm 身份真错配的恢复路径仍只有清库**：`_suspendedMetadata == null`（continuity 无法验证）
   时 resume 失败关闭，`SessionBootstrapController` 可能进入 `fatalError('无法恢复本地登录状态')`。
   这是有意的失败关闭（真正的密码学错配不得自动修复），但用户在极端情况下需要"清空聊天记录"
   或重装才能恢复。行为与本任务前一致，未新增死锁。
4. **测试中的 iOS 语义是建模而非真机**：`FakeMatrixClient` 复现了 SDK 的
   `init(newDeviceID:) → updateClient` 写回行为，但不是真实 SDK；真实 SDK 的
   `init` 分支（如 `checkHomeserver`、`encryption.init`）未在测试中覆盖。
5. **并发 suspend + login 竞争**：修复后不再留下半开状态且可重试成功，但"登录被 suspend
   打断后仍可能返回成功而实际没有活动 client"这一遗留语义未改变（测试中显式容忍）。
6. 全仓 `flutter analyze` 仍有 2 个 error，来自并行任务对
   `lib/features/transfer/chat_transfer_sheet.dart` 与
   `test/features/moments/moment_comment_composer_test.dart` 的未完成修改；本任务未触碰这些文件，
   也未据其结论声称全仓 analyze 通过。
