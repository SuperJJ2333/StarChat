# 发送方消息错序修复与 Mi 6 debug 验证

用户现象：发送方消息不在正确位置，退出房间再进入才恢复，接收方显示正常。用户授权同 debug 签名覆盖安装到 Mi 6，保留数据。

## 根因与修改

1. RoomTimelineController 永久用 `_sentAt` 和本地回声时间覆盖已确认消息的服务器时间，随后又按时间排序。手机时钟与服务器有偏差时，会话内与重进后的排序不一致；接收方没有该本地覆盖。移除此覆盖，真正确认后使用服务器时间，transaction 稳定标识保留。
2. 待发送气泡刚追加时在尾部，但下一次 refresh 按手机时间重新排序，可能退进历史。待确认和重试插入时间取 `max(手机当前时间, 当前列表最大时间+1微秒)`，不会在发送刷新时落到旧消息前。
3. Matrix 的 HTTP ACK（`sent`）仍携带手机时间，只有 `synced` 才是同步后的权威数据。适配器新增 `isSdkLocalEcho` 投影；HTTP ACK 阶段保留插入位置，sync 到达后再消费本地回声。
4. 定制 SDK 的 Timeline 遇到“sync 先到、ACK 后到”时原先替换整个事件、仅恢复 synced 状态，导致时间和正文仍被旧本地数据覆盖。现在已有 synced 事件拒绝晚到的 sent/sending/error 本地投影；后续同级 synced 更新仍正常应用。没有改变发送协议、加密或密钥处理。

## 回归与审查

- `red.txt`：3 个排序回归失败，复现手机慢导致 pending 回退，以及两种 ACK/sync 顺序下发送方与重进顺序不一致。
- `ack-red.txt`：真实适配器区分 ACK/sync 和 ACK 保持位置的回归失败。
- `sdk-red.txt`：真实 Timeline stream 注入 synced 后再注入 sent/sending/error，3 项均复现服务器 10:00 被改回手机 09:58。初始测试的时区比较已纠正为 UTC，并在未修复 SDK 时重跑取得有效 RED。
- 修改前两项测试错误地要求确认后永远保持本地时间；现改为保持稳定标识并采用服务器时间。
- 最终 Flutter 全量 **1290 项通过**；静态分析无问题。独立规格→质量审查提出 ACK 和 SDK 竞态两项 P2，补真实路径回归后复审通过。
- 另行执行 Flutter/Python 边界 **65 项通过**，UI 契约校验通过。
- 仓库完整校验未全绿：Business API/Worker **1052 passed、31 skipped、1 failed**，失败为 `tests/business_api/wallet/test_manual_reserve_monitor.py::test_unavailable_or_incomplete_reserve_pauses_without_publishing[liability]`，报 `ValueError: immutable deposit receipt lifecycle`。这是当前工作区本次未改动的钱包后台测试；本轮仅改 Dart/SDK 时间线，未修改或部署后端。完整日志见 `repository.txt`，不将其标注为 PASS。

## debug 交付

从 D 盘正式工作目录构建，保留此前相册、会话、好友及钱包改动；与 0.3.51 的源码指纹比较，Dart 产品代码仅变化两个时间线文件，另含上述 SDK 修复。未替换线上正式更新。

- 版本 **0.3.52-debug / versionCode 2054**，standard/debug/ARM64，三项 HTTPS 构建地址均为 `https://liuhetong888.com`。
- 设备 `cbd0156b / MI 6` 原包为 0.3.50-debug / 2052。证书从设备原 APK 实际核验，SHA256 为 `34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1`。最终包与原包证书一致。
- Apktool 2.12.1 重建，build-tools 36.0.0 对齐与签名验证通过。**24,912 个类**语义一致，**332 项原生库/资产**字节一致，清单语义一致。
- 最终 APK **140,838,977 字节**，SHA256 **fc59bf22c38aa6a14da074c78d9e34943f5a378bd2b92a93e6248804cc91fac5**。
- `adb install -r` 返回 **Success**，未使用卸载、清数据或降级参数。安装后 versionCode 为 2054；首次安装时间仍为 2026-09-05 08:52:18。
- 从设备回读新 APK，完整 SHA256 与最终包一致。启动 PID 26695，当前进程 crash buffer 中未发现崩溃标记；旧缓存中的两次崩溃早于本次安装，不计为本次启动。

未代用户给真实好友发消息，因此真实房间连续发送和滚动效果需用户本人验收。建议在同一房间连续发送、等待对方回复，观察无需退出重进即可保持顺序；再测试图片发送及失败重试。

本机证据与最终包：`artifacts/2026-09-07/sender-order-debug/`，大文件和日志不入 Git。
