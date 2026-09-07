# 主任务复用、房间草稿及空白加密摘要

## 范围与结果

1. Mi 6 最近任务中实际观察到两个 `com.liuhetong.mobile/.MainActivity`。主入口原为 singleTop + 空 taskAffinity，而推送与通话返回使用 NEW_TASK。这不能保证非栈顶启动时复用同一主任务。现改 singleTask、应用默认 affinity、documentLaunchMode=never；既有 CallActivity 通话处理不变。其 onDestroy 仅解除 UI 监听，不结束通话。
2. RoomPage 的实际输入监听、程序化编辑、发送清理、退出及后台生命周期均接入 RoomDraftStore。按 homeserver+Matrix 账号+房间的 JSON 数组摘要作为键，防止拼接歧义和跨账号串草稿。现有 FlutterSecureKeyValueStore 保存内容，无业务 API、日志或服务端明文。
3. 内存即时更新，300ms 防抖合并安全存储写入；退出/后台 flush，提交发送立即后台 flush 清理。每键串行写入，旧写入不能覆盖后续清理或新草稿；读回期间发生新输入/发送后不采用旧结果。
4. 原文（含换行和空格）及有效结构化 @ token 恢复。纯文本 @@ 不推断收件人；坏范围丢弃；草稿损坏不导致页面崩溃。回复引用/多媒体不是本次草稿范围。
5. 未解密事件与无事件的消息列表摘要直接空白；群聊提前返回，避免发送者冒号或摘要计数。解密后仍正常刷新；不删除历史、不修改密钥恢复或会话内解密提示。

## 验证

- Flutter 全量 1339 PASS；补充实际群会话空摘要 widget 与草稿并发/持久化等 8 项复核 PASS。
- Flutter analyze: No issues found。
- 标准/精简两变体 process*DebugMainManifest 均 BUILD SUCCESSFUL；逐一读取本次 merged_manifest 输出确认 singleTask/never/default affinity。
- Android 入口规则有旧配置 RED 和当前 GREEN；草稿、摘要有行为 RED/GREEN。UI contract drift PASS。独立移动边界最终 65 PASS / 1 FAIL：并行新增的 wallet/manual_mfa_page.dart 使用不符合现代操作按钮约束的组件，失败 test_business_pages_use_the_modern_action_system；该文件未纳入本次提交。
- 覆盖：房间/账号/服务器隔离、重启存储重建、发送清理、旧 read/write 竞争、结构化 @、损坏记录、群摘要真实接线。
- 规格复核：三项请求均落到实际入口。质量复核：无服务端明文、未改业务财务/解密边界；草稿保存不阻塞输入。
- 全仓库 verify 已执行：后端 1189 PASS / 31 SKIP / 1 FAIL。唯一失败为 tests/business_api/test_migrations.py::test_manual_wallet_migration_is_the_only_head：断言旧头 0051_monitor_delivery，工作区实际为并行钱包开发新增的 0053_handover。该测试文件已在本轮开始前修改，0053 为并行工作区未跟踪文件；均未纳入此次提交。不能声称全仓库通过。

## 设备与异常边界

此次没有构建可交付 APK，也未安装新包，所以不将源代码测试表述为 Mi 6 已修复或 Android 逐入口验收完成。需新包覆盖安装后依次从桌面、通知、通话返回，确认最近任务只复用主任务。旧版本已留下的任务卡片可能需要一次手动划掉，无需卸载应用。

系统安全存储写入失败时保留本次进程的内存草稿并保留失败状态（不打印草稿内容），后续编辑/退出/后台重试；若设备强制结束进程早于 300ms 写入及生命周期回调，最后一小段输入可能尚未落盘。卸载会清除 Android 本地数据，草稿不跨设备同步。失败发送仍保留在现有失败气泡，输入草稿不会自动重复恢复。

人工验收：A房间输入未发送文字→退出→B房间不同草稿→返回A；重启后再次确认；发送后重进为空；低网速进入时立刻输入，不可被旧草稿覆盖；重新安装登录后无法解密的会话摘要保持空白。

证据：`docs/verification/artifacts/2026-09-07/tasks-drafts/`（本任务于 09-07 启动，跨日完成）。
