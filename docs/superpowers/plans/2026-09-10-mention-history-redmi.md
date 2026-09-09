# 群聊提及、历史检索与 Redmi debug 交付

需求授权：2026-09-10 用户当前五项修复及真机安装指令。按此范围执行。

## 设计及文件所有权

本任务负责 mobile_flutter 的 room_page、matrix_home_page、conversation_list_tile、chat_search_page、room_timeline_controller、matrix_room_timeline_adapter；新增本地 mention store 与对应测试；同步 UI registry/ledger 的本地验证记录。保持当前工作区其他改动。

- 提及仅群聊：结构化 user_ids/room 提及，排除本人及撤回。首次以现有已读事件为边界；之后按事件 ID 持久化 pending/viewed，普通已读不清空。最新到最旧逐条跳转；前台当前路由消息可见高度达到 min(消息高度, 视口高度) × 50%，持续 500ms 后消费（超长消息按可见容量计算），失败不消费。个人设备状态，不声称跨设备同步。
- 提前两屏预取历史，单飞请求，按 Matrix 分页 token 判断耗尽；不插入加载行，保留反向列表稳定 key 和位置。
- 搜索从动态时间线取数据并按需分页；日期不把未加载日期当作无消息，按选定月份加载，按日期定位；保留媒体/成员/关键词组合筛选及陈旧请求防护。空数据明确提示，快速切月不允许旧结果覆盖。
- 搜索按钮使用已有 elevatedSurface / resolveTextPrimary，选中浅绿底深色字，只有实际选中分类高亮。

## 顺序

- [x] 增加回归测试并运行，记录预期失败。
- [x] 接通提及状态持久化、列表前缀、房间可见性和跳转。
- [x] 修正分页耗尽与提前加载，接通动态搜索和按月日期加载。
- [x] 修改按钮 token，验证浅深模式和分类选择状态。
- [x] focused tests、analyze、UI contract、verify.ps1；先规格审查，再质量安全审查。
- [x] 按 android-apk-rebuild.md 构建 ARM64 standard debug、Apktool 重建、固定签名、完整校验并 adb 安装 Redmi，保留数据（设备原包签名不一致，按显式 Gradle 参数构建 .debug 并存包）。

Figma 工具本次不可用，不能声称远端设计已更新；本地 registry/ledger 标注实际状态。真机交互验收由用户本人完成。
