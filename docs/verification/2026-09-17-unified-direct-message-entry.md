# 2026-09-17 「好友资料 → 发消息」统一入口（通讯录 / 朋友圈 / 群聊收敛）

本次只改「好友资料 → 发消息」的上层入口实现，不改 Matrix 房间创建、加密校验、
E2EE、群聊/朋友圈页面结构，也不改 `DirectChatController` / `CoordinatedDirectChatGateway`
的仲裁逻辑。**未构建、未安装、未部署**（用户自行处理）。

## 1. 现状与根因

`_ContactsTabPageState._openMessage`（`lib/app_home.dart` 内，与 `ContactsTabPage` 同文件）
是 AppHome `_openMessage` / `_openManagedRoom` 的第二份实现：

| 关注点 | AppHome `_openMessage`（朋友圈/群聊/会话资料在用） | 通讯录重复实现（改造前） |
| --- | --- | --- |
| 好友身份 | `_refreshMissingFriendIdentity(matrixUserId)` + 按**业务 userId** 取权威 `ContactDetails`，缺失时用入口快照回填 | 只按入口快照的 `matrixUserId` 判活，直接用 `contact.matrixUserId` |
| canonical 房间 | `directChats.open(...)`（同一 controller） | `widget.directChats.open(contact.matrixUserId)` |
| RoomLease/RoomPage | `_openManagedRoom`：`setOnRevoked` = `popUntil(自身)` + 当前则 `pop` | 页面内自建：`setOnRevoked` = `popUntil(自身)` + `removeRoute` + `await route.popped` |
| 失败提示 | `showDirectChatFailureDialog`（带分类与重试） | 同样的弹窗，但入口分叉后无法保证后续修复同步 |

风险（用户列出、本次确认存在）：身份校验不一致、stale `ContactDetails` 行为不一致、
Matrix ID 更新后通讯录可能继续用旧值、后续修 `_openManagedRoom` 时通讯录不会同步、
revoke 行为分叉、页面参数与错误/重试行为逐渐漂移。

## 2. 修改内容

### 2.1 通讯录删除重复实现（唯一入口）

- `ContactsTabPage` 新增 `required ContactAction onMessage`（AppHome 注入 `_openMessage`），
  删除页面内的 `_openMessage`（含自建 `openRoomLease` / `RoomPage` / `setOnRevoked` / push）。
- AppHome 构造处传入 `onMessage: _openMessage`；`ContactsPage` 与 `ContactProfilePage`
  本来就是「UI + action dispatcher」，原样把 `widget.onMessage` 透传给资料页，
  因此 `ContactProfilePage` 仍不知道 DirectChatController / canonical room / RoomLease。
- 顺带删除 `ContactsTabPage.reminderService`（只为被删除的重复 RoomPage 而存在）；
  `ReminderService` 在其他 RoomPage 入口（消息 Tab、建群）保持不变。

### 2.2 新增 `lib/features/matrix/direct_chat_entry.dart`（唯一身份解析，可单测）

- `resolveFriendContact(cache, entry)`：「发消息」的权威联系人解析。
  业务 `userId` 是身份主键：目录命中即用；缺失时 `preload` → 静默刷新一次；
  目录里 `userId` 与 Matrix ID 都不在，才抛
  `StateError('The contact is no longer a current friend')`（`classifyDirectChatFailure`
  已把它归类为「该好友已不在你的好友列表」）。
  目录里存在好友但 Matrix 绑定为空时，用入口快照补齐**通信映射**，并保留目录中的
  备注/标签/朋友圈权限/在线状态（备注是查看者私有数据，不能被入口快照覆盖）。
- `ensureCurrentFriendIdentity(cache, matrixUserId)`：原 `_refreshMissingFriendIdentity`
  逐字搬移（矩阵索引契约不变），仍服务于三条「只有 Matrix ID」的路径：
  接受好友后建会话、通话入口、通知入口。
- `directMessageOpenKey(contact)` / `DirectMessageOpenGate`：同一好友「发消息」的单飞闸门。
  `DirectChatController._openings` 合并的是**房间打开请求**，每个调用方仍会各自 push
  RoomPage；闸门从打开请求开始持有到 RoomPage 关闭（`push` 完成）或流程失败为止，
  阻止同一好友叠加多个 route。失败时**先释放再弹窗**，否则弹窗「重试」同步回调入口时
  会被自己的闸门挡掉。

### 2.3 AppHome 统一入口

```dart
Future<void> _openMessage(ContactDetails contact) async {
  final openingKey = directMessageOpenKey(contact);
  if (!_directMessageGate.claim(openingKey)) return;      // 同一好友单飞
  try {
    final cache = await _identityCache();
    final authoritative = await resolveFriendContact(cache, contact);
    final reference = await directChats.open(authoritative.matrixUserId.trim());
    await _openManagedRoom(reference.roomId,
        roomName: authoritative.displayName,
        initialContact: authoritative, cache: cache);      // 权威联系人，不是旧快照
  } catch (error) {
    _directMessageGate.release(openingKey);                // 重试可重新进入
    if (!mounted) return;
    await showDirectChatFailureDialog(context, error,
        onRetry: () => _openMessage(contact));
    return;
  } finally {
    _directMessageGate.release(openingKey);
  }
}
```

`_openManagedRoom` **未改动**（用户要求）：它已覆盖未 mounted 时 `lease.cancel()`、
push 抛异常时 `finally { await lease.cancel(); }`、revoke 时 `popUntil(自身)` 且当前则 `pop`
（不会多 pop 或 remove 错 route）。`DirectChatController`、`CoordinatedDirectChatGateway`、
`createOnce/findExisting/findCached/intent store/claim/publish` 全链路未改动。

## 3. 入口审计结果（用户要求逐项检查）

| 入口 | 结论 |
| --- | --- |
| 通讯录 → 好友资料 → 发消息 | **改**：删除重复实现，改为 AppHome 统一入口（A1） |
| 朋友圈 → 好友头像/昵称 → 资料 → 发消息 | 已统一（`openMomentPerson` → `ContactProfilePage(contactActions.onMessage)`）；非好友仍 `AddFriendProfilePage`，SELF 逻辑不变，未改动 |
| 群聊 → 群成员 → 好友资料 → 发消息 | 已统一（`openGroupMemberProfile`：好友 → `onOpenFriendContact` → `_openContact` → `ContactProfilePage(onMessage: widget.onMessage)`；非好友 → `AddFriendProfilePage`；自己 → 直接 return），未改动 |
| 会话资料/消息头像（RoomPage 内） | 已统一（`_openPeerProfile`/群资料成员点击均传 `ContactActions(onMessage: widget.onMessage)`），未改动 |
| 好友申请接受后建会话 | 仍走 `FriendAcceptanceCoordinator` + `ensureCurrentFriendIdentity(cache, matrixUserId)` + `directChats.open`（本就不推 RoomPage），未改动 |
| 通知/通话入口 | `ensureCurrentFriendIdentity` 矩阵索引契约不变；**通话入口仍使用入口快照的 `contact.matrixUserId`**（见第 5 节遗留项） |

`ContactProfilePage` 保持纯 UI + action dispatcher（`widget.onMessage?.call(contact)`），
本次未改。错误提示仍统一走 `showDirectChatFailureDialog`（含分类文案与可重试判定）。

## 4. 验证

| 命令 | 结果 |
| --- | --- |
| `flutter analyze`（全量） | 退出码 0，`No issues found!` |
| 定向（direct_chat_entry + 接线 + 通讯录透传） | 13 通过 / 0 失败 |
| 受影响面（contacts + matrix 相关 + app_home_lifecycle） | **127 通过 / 0 失败** |
| `flutter test`（全量） | 退出码 0，**2721 通过 / 0 失败**（本任务前 2712）。日志 `artifacts/2026-09-17/flutter-full-direct-message-entry.txt` |

新增/改写的用例：

- `test/features/matrix/direct_chat_entry_test.dart`（新增 9 项）：
  ① 目录缺失该好友 → 静默刷新一次后返回权威联系人；
  ② 好友已缓存 → 不再发请求；
  ③ **入口 Matrix ID 已过期 → 以 userId 取到的当前映射为准（旧实现会判「已不是好友」）**；
  ④ 业务 userId 形态不同但 Matrix ID 仍是当前好友 → 用目录条目；
  ⑤ 目录缺 Matrix 绑定 → 用入口快照补齐映射且保留本机备注，双索引可查；
  ⑥ 非好友（两个索引都没有）→ 抛可分类的 `StateError`；
  ⑦ `ensureCurrentFriendIdentity` 矩阵索引契约（命中不请求 / 未知刷新后失败）；
  ⑧ 单飞闸门去重、释放、不同好友独立、空键不参与；
  ⑨ 打开键优先 userId、缺失退回 Matrix ID。
- `test/features/matrix/profile_message_route_wiring_test.dart`（改写）：
  生产 RoomPage 入口仍带 `onMessage:`；AppHome 统一入口按权威 `matrixUserId` 打开并经过
  闸门；**`ContactsTabPage` 段不得出现 `openRoomLease` / `builder: (_) => RoomPage(` /
  `setOnRevoked` / `directChats.open` / 自己的 `_openMessage`**；`CoordinatedDirectChatGateway`
  与 `_openCanonicalDirectRoom` 仍在位，且 AppHome 不出现 `createEncryptedDirectRoom(`。
- `test/features/contacts/direct_message_identity_test.dart`（改写）：
  通讯录把注入的统一入口**同一函数对象**透传给 `ContactsPage`，且资料页「发消息」
  调用的就是这个入口（联系人快照原样传入，由入口重新解析权威身份）。
- `test/features/contacts/contacts_group_entry_test.dart`：补 `onMessage` 参数。

变异探针（改动后复原）：

| 变异 | 结果 |
| --- | --- |
| `resolveFriendContact` 去掉 userId 主键分支（退回矩阵索引） | 2 个身份用例失败 |
| 通讯录 `onMessage: null`（不再透传统一入口） | 接线 + 透传用例失败 |
| 去掉 `_directMessageGate.claim(openingKey)` | 接线测试失败 |

## 5. 行为变更与遗留项（供评审/后续任务）

1. **身份解析改为 userId 主键**（用户第八节要求评估的点）：Matrix ID 已更新的旧快照
   现在能正常打开会话；旧实现会在刷新后仍按旧 Matrix ID 判死并抛「该好友已不在你的好友列表」。
   非好友、断网等失败路径文案与分类不变（`classifyDirectChatFailure` 未改）。
2. **入口快照不再整体覆盖目录条目**：只补 Matrix 绑定，保留目录里的备注/标签等本机字段。
3. **重复点击语义**：同一好友在途打开或该会话已打开时，再点「发消息」是**无操作**（不再叠加
   第二个 RoomPage）。若产品希望改为「回到已打开会话」，需要引入房间级路由注册表。
4. **遗留（未修，超出本次范围）**：从消息列表直接打开的 RoomPage（`matrix_home_page.dart` 自己
   `openRoomLease` + push）不经过 AppHome，因此在那个会话里点对端头像 → 资料 → 发消息，
   仍可能为同一个房间再 push 一个 RoomPage。彻底修复需要把消息列表的 RoomPage 入口也收敛到
   `_openManagedRoom`（并让闸门知道「该房间已在栈上」），属于下一轮入口统一工作。
5. **遗留**：通话入口（`_openCall`）仍按入口快照的 `contact.matrixUserId` 打开房间并做矩阵索引
   校验；本次未动（用户要求不改无关功能），如需与「发消息」一致，可改用
   `resolveFriendContact`。
6. **建群路径**（`_createGroupChat` 成功后推 RoomPage）保留自己的 RoomPage/revoke 写法
   （与 `_openManagedRoom` 略有差异），本次未动：它不属于「好友资料 → 发消息」。
