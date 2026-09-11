# Mi 6 撤回源码修复交接

记录时间：2026-09-10 23:47 +08:00。工作树：`codex/moments-im-mi6-20260910`；基线 `8ec6782e`。本分工只修改撤回服务/菜单策略、Matrix 时间线投影和既有 SDK 时间线/数据库。`room_page.dart` 由主代理集成。阶段起始精确时间未记录，耗时未知，不从文件时间反推。

授权：[本次计划](../superpowers/plans/2026-09-10-moments-im-mi6.md)。用户要求无需自行测试，本分工未运行自动化测试、analyze、构建或真机操作；以下为源码链路证据，不声称已复现或验收通过。

## 根因与改动

1. `matrix_e2ee_client.dart` 的 `_SdkRoomTimelineCapability.snapshot` 只接受 `m.room.message` 等展示事件。已解密消息被撤回时可暂时保留该类型，但服务器/数据库的撤回加密信封仍是 `m.room.encrypted`，后续投影会过滤掉。现在也接受 `event.redacted && type == m.room.encrypted`，以原事件 ID、发送者和时间生成占位；未撤回的未解密事件不受此条件影响。
2. SDK `timeline.dart` 和三套数据库的 `storeEventUpdate` 只读顶层 `redacts`。`client.dart` 已支持 `content.redacts`，上下游不一致。现在时间线与持久化同时兼容两种目标字段，并避免没有目标时匹配任意事件。
3. 已存在事件被迟到历史/同步/解密结果替换时，原路径不保留已确认撤回。时间线保留已有 `redactedBecause` 并清除内容；数据库把已有撤回状态合并到同 ID 的迟到事件、清空内容后继续持久化，确保 limited sync 清除 fragments 后也能恢复占位索引。使用原有 Matrix `unsigned.redacted_because`，不新增撤回表、明文日志或内存伪占位。
4. `MessageInteractionService` 与 `MessageCapabilities` 原来均为两分钟，现为三分钟（包含精确三分钟）。发送者与服务端时间检查保留。业务卡片/系统消息既有限制保留。
5. SDK 撤回关系事件时的提前返回也会绕过目标清理与末尾更新，现在撤回目标后完成通知。

## 源码审查

规格：自己的已发送普通消息三分钟内展示撤回入口；重建后的撤回消息不以正文或附件展示。主代理需把接收方文案改为“对方撤回了一条消息”，自己的文案为“你撤回了一条消息”；仅存在本机草稿时提供重新编辑。

质量/安全：修改保持 Matrix 为撤回权威；没有业务 API 或新的持久化方案；SDK `setRedactionEvent` 清空原内容及 `original_source`，本次没有削弱加密/权限边界。所有三个数据库后端保持相同撤回目标与不可恢复覆盖规则。已人工核对 Dart API、导入与差异，`git diff --check` 对拥有文件退出码 0；未执行功能测试。

回归源码：`sdk_recall_persistence_test.dart` 新增旧/新版撤回目标、新消息、迟到历史、重开数据库和实时覆盖场景；已有 service/policy 测试调整三分钟边界。源码存在不代表运行通过。

下一步：主代理完成 UI 文案集成和最终构建交付；用户验收双方文字/图片/语音撤回、2:59/3:00/3:01 边界、继续发消息、切换房间、重启、断线重连及同账号多设备同步。分页历史中占位仍服从原有历史加载与用户本地删除规则。
