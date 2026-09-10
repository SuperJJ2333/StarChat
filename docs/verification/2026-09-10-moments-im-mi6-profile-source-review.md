# Mi 6 朋友圈资料动作与评论手势源码交接

日期：2026-09-10，Asia/Hong_Kong。工作树 `codex/moments-im-mi6-20260910`，基线 `8ec6782e`。精确阶段起始时间未记录，耗时未知。授权见 [计划](../superpowers/plans/2026-09-10-moments-im-mi6.md)。用户明确无需自行测试，本分工未执行测试、analyze、构建或设备操作。

## 根因与修复

1. `moment_person_navigation.dart` 创建 `ContactProfilePage` 时没有传入消息/语音/视频回调，因此 `FriendActionColumn` 三项失去功能。新增不可变 `ContactActions` 回调束，从 AppHome 已有动作显式传入发现/我→朋友圈列表→详情/个人朋友圈→作者、评论人、回复人资料。联系人资料→朋友圈预览→个人页的后续跳转也保留相同回调。
2. 全局搜索也直接创建无回调的好友资料；添加朋友资料的朋友圈预览也会丢失后续动作。消息/通讯录/发现的搜索与添加入口统一传递动作。群成员非好友资料入口由 root 在 `room_page.dart` 追加同样传递，未由本分工修改该文件。
3. 通话动作此前缺少消息动作已有的身份补载。规范私聊协调器需要 `contactsByMatrixId` 映射业务 ID，而朋友圈可能刚从服务端查询到了缓存缺失的好友。`_openCall` 先复用 `_identityCache` 与 `_refreshMissingFriendIdentity` 再进入协调器。
4. 评论交互条件 `longPress || own` 把自己评论短按错误当作菜单。现在自己评论短按立即返回，长按才显示复制/删除。根 Navigator 级弱引用锁避免重复打开评论菜单，finally 释放；其他人短按回复、长按复制以及动态作者删除权限保持原样。

## 私聊与边界源码审查

所有新增动作继续调用 AppHome `_openMessage` / `_openCall` → 同一 `DirectChatController` → `CoordinatedDirectChatGateway`。现有网关先读取权威规范房间；查询/加入/校验失败直接抛出，不因异常回退新建。仅权威不存在且取得 create/publish 许可后才调用既有 createOnce，跨设备由业务协调器按双方 ID 仲裁，本次没有新增房间创建实现。遗留私聊服务未发现 UI 直接调用点。

规格审查：列表、详情、个人朋友圈所有 person 入口均走 openMomentPerson；新回调可以跨 root Navigator 页面继续传递。自己短按无菜单/输入框；长按复制删除菜单单实例。

质量/安全审查：没有新的全局账号动作注册表、Matrix 客户端或持久化；按钮回调仍由已登录 AppHome 所有；失败处理保留；财务、鉴权、加密契约无修改。

## 源码证据与未测项

- 修改既有 `moment_comment_in_place_test.dart` 自己短按断言；新增连续调用长按菜单、关闭后重开的回归源码。未运行，不宣称红绿通过。
- Dart formatter 解析本分工 14 个 Dart 文件退出码 0；工作树缺少 package config，出现 flutter_lints include 无法解析警告，未把它当 analyzer 通过。为控制差异，保留未改代码的原始排版。`git diff --check` 本分工文件退出码 0。
- 未执行：消息/语音/视频真机操作；双方同时首次建聊；网络错误/超时/重新加入；新好友身份补载；朋友圈各入口和连续返回跳转；评论复制剪贴板、删除失败/成功、重连及权限变化。
- root 下一步：确认 room_page 的 group member contactActions 传递，完成 Mi 6 debug 集成/构建交付，由用户功能验收。

## 撤回模块交叉审查

先审规格后审质量：三分钟条件、encrypted redacted 投影、旧/新 redacts 解析和保留 redactedBecause 符合本轮目标。发现三套数据库新增 guard 的提前 return 会跳过 timeline fragment 插入：limited sync 的 deleteTimelineForRoom 只清索引，保留事件；迟到未撤回版本重放时占位会失去索引。已向 root/recall 负责人报告，要求把既有撤回合并进新事件后继续原状态/索引流程，并增加清索引后重放的回归源码。最终修复结果以 recall 交接为准。
