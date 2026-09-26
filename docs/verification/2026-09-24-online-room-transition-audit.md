# 在线切房卡顿调查

## 现场与结论边界

用户报告 v0.4.6：输入文字、收键盘、退出房间、进入另一房间在线卡顿，断网重复操作流畅，多设备存在。完整 build、包类型与真机帧时间尚未核验。不能把网络相关性直接等同于服务器慢。

调查对象为主目录源码；开始读取基线为 9cfcd00c，调查期间另一任务提交钱包缓存变更后 HEAD 为 8ed729a1。既有冷启动修复仍为未发布修改。本次不改生产实现、不构建或发布安装包。

## 已确认的重复处理链

1. `matrix_e2ee_client.dart:6183` 的 `_attachDecryptionListener` 监听 SDK `onEvent`，凡包含 event_id 的事件都会走到 6222 的全局 `_syncEvents.add(null)`；不限当前房间。成功的显式 sync 也在 6338 发出该通知。
2. 每个打开的逻辑时间线在 1729 监听此全局流，调用 `attachSources`。即使没有增加任何历史来源，1710 仍调用 `onUpdate()`。
3. `room_page.dart:1111` 的回调调度成员元信息刷新与时间线刷新；1582 读取 `roomLease.roomInfo`，经 `matrix_e2ee_client.dart:2333` 重新遍历、构造成员快照，再逐项比较成员。
4. 相同全局流还驱动 `matrix_home_page.dart:589` 的提及扫描、会话快照、成员刷新等，并驱动 `app_home.dart:549` 的总未读计数。成员请求已有并发合并/刷新策略，会话快照已有合并及差异缓存，不能描述成每次通知必发完整网络请求或必重画全屏。但未改变结果之前，部分扫描和快照构建已经发生。

这是与在线/离线差异吻合的明确多余工作来源。尤其其他群大量消息也会触发当前房间成员计算；按帧合并并不等于不做无关计算。其对用户设备的具体耗时及贡献比例尚未实测。

## 另一个待量测的放大点

每次进房 `room_page.dart:1178/1308` 打开表情仓库；`openEmojiVaultBackend:1739` 创建新 backend，而 `matrix_emoji_vault.dart:118` 的 session 缓存按 backend 对象保存，不能直接跨房共享。1329 无条件后台 refresh，3955–3964 的 loadEvents 会调用完整历史分页（每页100）。是否产生重复网络取决于本地历史覆盖情况，不能说每次必从网络下载全历史。页面退出未取消该 refresh，可能使快速切房时仍有后台工作重叠。

## 三个操作到底有多少加载

这不是固定串行的“三层网络加载”。

| 操作 | 必要路径 | 附带工作/等待 |
| --- | --- | --- |
| 收键盘 | 焦点、输入法 inset、布局动画 | 未见主动等待 HTTP；在线事件处理会与动画竞争 UI isolate |
| 退出房间 | 导航反向动画、dispose、草稿落盘与缓存释放 | 草稿 flush 为 unawaited；列表关闭回调重新请求会话快照；部分已启动后台任务尚未结束 |
| 进入已知房间 | 本地开房策略→资料缓存→lease→路由首帧→本地时间线 | 成员、身份、表情等异步工作启动；缺失历史/锚点可能额外请求网络；不能把缓存 future 数量当网络次数 |

正常已有会话的首帧目标应为零网络依赖。需要保留后台同步、解密与正确的权限检查，而不是断网或停止接收消息。

## 已排除的错误归因

- 未见输入每个按键发送 typing 请求的路径；输入主要保存本地草稿、更新提及状态。
- 时间线已有按帧合并及相同展示跳过发布；不能声称每条通知都会重绘全部消息。
- `_withClient` 在 operation 前释放生命周期队列，不会因为普通网络请求直接持锁。
- 主 lease.cancel 确有全局队列等待 owner drain 的潜在风险，但正常路由退出没有调用主 lease.cancel；子历史 lease 不绑定 owner drain。因此不能把配置中的5秒 timeout当成这次正常切房的实测原因。主 lease 未释放是另一个待修资源生命周期问题，不能简单追加 cancel 把潜在排队引入正常退出。
- 消息检索可能参与更新链，但目前没有证据表明它是唯一或主要原因；清缓存、换手机、升级服务器均不是已证实的针对性修复。

## 修复次序与验收

1. 将全局通知改为携带变化范围，逻辑来源仅在关联关系改变时刷新；成员快照仅在成员/名称/权限变化时失效。保留真实消息、撤回、编辑、解密完成与跨房历史关联更新。
2. 会话列表按脏房间合并更新；导航动画期间延后非紧急投影，避免无关群消息重复处理当前房间成员。
3. 表情元数据以账号为生命周期缓存并合并刷新，保证新增/删除事件最终一致；先验证跨房重复分页计数，再决定增量持久化方案。
4. 单独修复 lease 所有权：立即阻止已退页面发布，后台收尾不得阻塞其他房间；保留账号切换/密钥撤销所需的安全 drain 边界。
5. 同版本 profile/release 真机对比断网、普通在线、其他群消息突发与弱网；分别采集收键盘/退出/进房首帧 p50/p95、UI/raster 帧时间、当前房间成员快照次数、无关同步回调数、历史请求次数。不得上传消息正文或凭据。

## 计数复现与检查

新增 `apps/mobile_flutter/test/performance/room_unrelated_sync_diagnostic_test.dart`，使用真实 MatrixSdkE2eeClient、逻辑时间线及 SDK Timeline，仅替换客户端传输与初始空时间线加载。两项测试均表征现状，不是“修复通过”断言：

- 无关房间 sync 完成：逻辑回调由1次初始化增至2，SDK当前房间回调仍为0，当前消息仍为空；再发送无关房间普通事件，逻辑回调增至3，SDK回调仍为0。
- receipt-only sync：逻辑回调由1增至2，SDK回调0，当前消息仍为空。

执行 `flutter test --no-pub --reporter expanded test/performance/room_unrelated_sync_diagnostic_test.dart`，最终 exit0，2 passed、0 failed。`dart analyze` 此文件最终exit0/no issues；首次发现两处无效非空断言，修正后重跑分析及测试，原日志保留。

证据：`docs/verification/artifacts/2026-09-24/online-room-transition/diagnostic-test-final.log`（原主工作树的忽略归档，不随 Git 交付）、`docs/verification/artifacts/2026-09-24/online-room-transition/diagnostic-analyze.log`（原主工作树的忽略归档，不随 Git 交付）、`docs/verification/artifacts/2026-09-24/online-room-transition/identity.json`（原主工作树的忽略归档，不随 Git 交付）。未变生产实现，不运行构建及全仓门禁。日志证明额外通知存在，不测量Android掉帧，也不证明本次卡顿已经修复。
