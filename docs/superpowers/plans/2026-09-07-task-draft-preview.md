# 主任务复用、会话草稿与未解密摘要

用户本轮请求即执行范围。修改 Android 主入口任务策略、RoomPage 草稿接线、独立本机草稿存储和会话摘要；不修改钱包、推送业务或 E2EE 解密流程。

1. 用设备最近任务、manifest/入口链路确认重复主任务；MainActivity singleTask、默认应用 affinity、documentLaunchMode never，保留 CallActivity 独立呈现。
2. 账号+homeserver+room 隔离安全存储；内存即时更新，300ms 合并磁盘写入，退出 flush；恢复不可覆盖用户新输入；发送时清理草稿；保留有效结构化 mention token，不由纯文本推断。
3. 未解密会话摘要为空，解密后正常更新；群聊不得残留发送者冒号/计数拼接。
4. 写 RED 测试，实施最小修复，聚焦及全量 Flutter/analyze、Android入口检查；记录设备验证限制。
