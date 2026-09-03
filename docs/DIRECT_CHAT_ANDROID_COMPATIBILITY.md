# Direct Chat Android 兼容性说明（好友系统重构 BUG 4）

**日期：** 2026-09-03
**问题：** Android 9（API 28，RedMi Mi 6 等）上一对一私聊被本地缓存为
"二人群聊"——`m.direct` 账户数据写入与本地 sync 之间存在时序差，房间在
`isDirectChat` 尚未就绪时被消费/缓存。

## 修复设计

### 创建路径（`lib/features/matrix/matrix_direct_chat_adapter.dart`）

```dart
final roomId = await client.startDirectChat(
  matrixUserId,
  enableEncryption: true,   // 显式：绕过"对方无密钥→明文"的 SDK 默认
  waitForSync: true,        // 等房间以 join 状态进入本地 sync
  preset: CreateRoomPreset.trustedPrivateChat,
);
```

SDK `startDirectChat`（matrix 0.34.0，client.dart:752-820）内部完成：
1. `getDirectChatFromUserId` 查已有 DM → joined 直接复用；
2. invite 态自动 `join()`（不joinable 则继续新建）；
3. `createRoom(invite:[mxid], isDirect:true, preset, initialState)`；
4. `waitForRoomInSync(join:true)`；
5. `Room.addToDirectChat(mxid)` 写 `m.direct` 账户数据。

**创建后校验（禁止把未同步房间缓存为群聊）：**

```text
校验 room.isDirectChat == true && room.directChatMatrixID == target
  不满足 → addToDirectChat 补写 → 等待 sync（至多 3 次 × 300ms）
  仍不满足 → 抛 StateError（不返回房间号，绝不缓存）
```

最终防线：`DirectChatService._requireSafe`（encrypted + join/invite 恰好两人 +
participantIds 含目标 MXID），复用/新建/规范房间三条路径全部经过。

### 不健康旧房间的修复（2026-09-03 追加：Mi 6"无法打开加密会话"）

真机根因：好友曾 **invite→leave** 退出旧 DM（服务端 `room_memberships`
可查），`_snapshot` 按 join+invite 统计仅剩 1 人 → `_requireSafe` 硬抛错。
且 SDK `startDirectChat` 对 joined 的旧 DM **直接复用不重邀**，新建路径
同样拿回坏房间——两条路径全部死锁。

修复（`DirectChatService.openOrCreateDirectChat` 三级策略）：

1. **原地修复优先**（`MatrixDirectChatBackend.repairDirectRoom`，保留聊天历史）：
   - 对方已退出（参与者仅剩自己）→ `room.invite(target)` 重新邀请；
     invite 计入双人校验，对端打开会话时经 invite 扫描自动加入；
   - 未加密但双人齐全 → `room.enableEncryption()` 补发 `m.room.encryption`；
   - 修复后短暂轮询（3 × 300ms）等待加密标志同步到位。
2. **不可修复（多人房间/成员不含目标）→ 绕开新建**：
   `createEncryptedDirectRoom(avoidRoomId: 旧房间号)`——SDK 复用路径命中
   坏房间时改走显式 `createRoom(isDirect+initialState 加密)` 并重指
   `m.direct`，绝不返回坏房间。
3. **Canonical 失效回退**（`CanonicalDirectChatGateway`）：登记的规范房间
   打开失败（如已被替换）时回退本次新建的有效房间，禁止死锁报错。

服务端复核方式：修复路径生效后，旧房间的对端成员应出现新的 `invite`
成员事件（原 `leave` 被覆盖）。

### 结构化日志（BUG 4 要求字段）

`developer.log(name: 'DirectChat')`，一次性输出：

```text
DirectChatCreate sdkInt=see-native-log roomId=!x:hs target=@bob:hs
  isDirectRequest=true mDirectBefore=false mDirectAfter=true
  roomIsDirect=true roomDirectTarget=@bob:hs encrypted=true
  waitForSync=true dbPersisted=true
```

（Dart 层不读 Build.VERSION；`adb shell getprop ro.build.version.sdk` 与
logcat 对照获取 sdkInt。`sdkInt=see-native-log` 为占位。）

### Canonical 复用（Phase E）

打开私聊先查业务侧规范房间（`GET /direct-conversations`），存在直接复用——
同对好友跨设备/重装不再产生重复房间；对端建的房间我方为 invite 态时自动
join 后再校验。详见 `docs/FRIEND_SYSTEM_REFACTOR.md` §4。

## 测试矩阵

| 设备/系统 | 全新安装 | 旧版本升级 | 清数据登录 | 同账号双设备 |
| --- | --- | --- | --- | --- |
| Android 9（API 28，Mi 6 真机） | ✅ 2026-09-03 实测 | ✅ 2026-09-03 实测（0.3.28 覆盖安装） | ✅ 2026-09-03 实测 | ⏳ 待第二台设备 |
| Android 10 | ⏳ 无设备 | ⏳ | ⏳ | ⏳ |
| Android 12 | ⏳ 无设备 | ⏳ | ⏳ | ⏳ |
| Android 13 | ⏳ 无设备 | ⏳ | ⏳ | ⏳ |
| Android 14 | ⏳ 无设备 | ⏳ | ⏳ | ⏳ |
| Android 15/16（RedMi K80） | ⏳ 待用户侧验证（无 adb 连接） | ⏳ | ⏳ | ⏳ |

真机验证清单（每格）：
1. 好友 accept → 消息页即时出现会话 + 系统招呼"你已添加了 XXX…"；
2. 打开私聊发送消息 → 对端收到；房间为 1v1（非群聊）且 E2EE；
3. 退出重进/重启 App → 会话仍为私聊（不退化为群聊）；
4. 对端删好友重加 → 复用规范房间，不产生重复会话；
5. logcat 过滤 `DirectChat` 检查 `mDirectAfter=true roomIsDirect=true`。

## 回滚

纯客户端行为（无服务端强依赖；canonical 端点失败自动回落原路径），
回滚 = 还原 `matrix_direct_chat_adapter.dart` 与
`direct_chat_controller.dart` 两个文件后重新构建。
