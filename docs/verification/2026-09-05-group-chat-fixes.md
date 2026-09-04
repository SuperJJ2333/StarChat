# 群聊功能修复验证（2026-09-05）：成员邀请 / 群二维码 / 入群通知 / 群聊通讯录

任务：四个群聊 BUG 修复（测试先行），Matrix 保持群成员关系唯一权威，
E2EE 零改动，不 push 不部署，单个本地 commit。

## 1. 根因与修复对照

### BUG1 添加成员后只增加人数，新成员没有真正进入群聊

**根因**（实证）：添加成员只调 `room.invite()`（group_chat_info_controller.dart:277）；
建群流程调 `/groups/auto-join` 但添加成员从不复用；info 页把 invite+join 全部
计入人数（:194-206）；被邀端自动入群只在三处手动 sync() 路径执行且不查
`auto_allow_group_join` 设置；服务端不校验操作者是否在房间、幂等键从未落库。

**修复**：
- 服务端 `/groups/auto-join` 加固：`get_room_state()` 校验操作者 join 成员 +
  每个被邀者有 sender=操作者的 invite 事件（证明 Matrix 已鉴权邀请权）+
  分桶 `joined/pending/failed` + `IdempotencyRecord` 真实落库 + AuditEvent 留痕
- info 页 `members` 只含 join、`invitedMembers` 单列"等待加入"区；标题人数
  =joinedCount
- `invite()` 两步：Matrix invite（权威）→ 服务端自动入群（授权代加），按
  分桶如实呈现（对方已加入/等待确认/部分失败）
- home 页订阅**实时 onSync** 处理新邀请：设置开→立即 join；设置关→渲染
  待处理邀请 tile（接受=joinRoom / 拒绝=leave）

### BUG2 群二维码没有实装

**根因**：`GroupQrCodePage` 是 `Icon(qrcode)` 图标占位（:621-647）；
扫码只识别 `changliao://u/`；群设置存个人 account data 服务端不可见。

**修复**：
- 服务端五端点：签发（群主/管理员，token_urlsafe(32) 存 sha256，7 天默认
  过期）/摘要（不含 room_id）/兑换（直加或转审批，join 带 `com.changliao.
  join_source='qr'` 标记）/撤销/审批流（approve/reject）；OpenAPI 已同步
- 客户端：`group_qr.dart` 编解码（`changliao://g/<token>`，>=16 字符防伪造）；
  `GroupQrCodePage` 实装（QrImageView 真码 + 过期提示 + 刷新=轮换 + 关闭态）；
  `ScanQrPage` 双分流（群码→确认页→redeem→成功打开会话；好友码原路径不变）；
  过期/撤销/关闭/无效给明确错误

### BUG3 新成员入群没有系统通知

**根因**：时间线适配器（:31-41）过滤掉全部 m.room.member 事件。

**修复**：`group_join_notices.dart` 纯函数本地推导——只认"真正 join"转变
（prev != join → join），配对 invite 事件取邀请者；invite-only 不显示；
相邻同邀请者合并批量文案；join content 带 qr 标记→扫码文案；姓名本地
解析绝不写回 Matrix；经 `RoomMessageKind.system` → `WeChatNudgeNotice`
居中灰字渲染（与拍一拍/撤回一致）；重载历史一致（推导自持久事件）。

### BUG4 通讯录—群聊错误跳转到发起群聊

**根因**：contacts_page.dart:294-298 tile → `onGroupChat` → app_home
`_createGroupChat`。
**修复**：新 `GroupAddressListPage`（join + !direct + saved==true，按
最近活跃倒序，头像拼图，空态，onSync+AnimatedBuilder 即时刷新）；tile
→ `onGroupAddressList`；"+"菜单保留发起群聊不变。

## 2. 数据流

### 好友邀请
```
邀请者选好友 → room.invite()（Matrix 鉴权邀请权）→ POST /groups/auto-join
  服务端: actor 认证 → get_room_state → 操作者 join? → 每人 invite 由操作者发出?
  → 好友? → auto_allow 分流 → admin gateway join_room_as_user（60s 令牌）→
  审计+幂等 → {joined, pending, failed} 分桶 → 客户端按桶提示+刷新
被邀端: 实时 onSync → 设置开→autoJoinInvitedRoomIds+oneShotSync → 群会话出现
        设置关→待处理邀请 tile → 接受=joinRoom / 拒绝=leave
```

### 扫码入群
```
群主生成 → POST /groups/{room}/join-tokens（moderator 校验）→ 7 天令牌
扫一扫 → parseGroupQrPayload → GET /groups/join-info（安全摘要，无 room_id）
  → 确认页 → POST /groups/join-tokens/redeem
    qr_join_enabled 校验 → join_approval_required?
      no  → admin gateway join（带 qr 标记）→ {status:'joined', room_id} → 打开会话
      yes → group_join_requests(pending) → 管理员 approve → join
```

## 3. 安全控制（新增）

| 控制 | 位置 |
|---|---|
| 操作者房间成员校验 | groups.py auto_join: get_room_state + join 检查 |
| invite 配对（证明 Matrix 已鉴权） | groups.py: invite sender == operator |
| 好友关系硬边界 | groups.py: 非好友整单 403 |
| moderator 权力级（签发/撤销/审批） | groups.py: power >= max(50, invite_level) |
| 令牌 sha256 存储（明文绝不久留） | groups.py + migration 0036 |
| 幂等键真实落库 | groups.py `_idempotent_replay`（IdempotencyRecord） |
| AuditEvent 留痕（5 个动作） | groups.py audit.record × 5 |
| join_content 白名单 | matrix_admin.py: 仅 `com.changliao.join_source` |
| 群码不含房间 ID/凭据 | group_qr.dart + 服务端 token 随机 |
| E2EE 零改动 | 无密钥/明文经 Business API |

## 4. 测试证据

| 套件 | 结果 |
|---|---|
| 服务端 `tests/business_api/groups/` | **11/11**（操作者校验/invite 配对/分桶/幂等重放/令牌生命周期/审批流/关闭拒绝/过期/哈希不落明文） |
| `tests/business_api/`（全量） | **272 passed**（含合同/迁移链/OpenAPI） |
| Flutter 全量 `flutter test` | **731/731**（+28 新增） |
| flutter analyze | 0 issues |
| scripts/verify.ps1 | PASS（OpenAPI PASS / Compose render PASS） |

## 5. 人工验证清单（无真机环境，如实标注）

- A 建群→A 从聊天信息添加 B→B 无需重启收到群会话
- B 能查看群信息并收发加密消息
- 双端各一条入群通知（含批量/扫码文案）
- C 扫群码→确认页→加入（/需审批场景）
- 关闭"二维码进群"后旧码 410
- "保存到通讯录"开关即时反映到通讯录群聊列表

## 6. 已知限制

- `_FakeGateway` 的 gateway 接口扩展（listContacts）为测试桩内部实现。
- 扫码确认页的 `onJoined` 由组合根注入；发现页扫码不自动跳转（返回消息列表可见）。
- group_join_requests 的 pending 幂等唯一索引是部分索引（PostgreSQL），
  SQLite 测试库由查询级检查兜底。
