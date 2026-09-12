# 历史检索、历史滚动与群聊接收延迟排查

状态：部分代码修复已提交；日期检索功能改造及实际50秒接收延迟仍未完成，未打包/安装新Debug。用户明确反馈为别人已发送但本人晚收到，报告版本0.3.87-debug/2096；事件时间与群名未取得。

工作树`.worktrees/offline12`，分支`codex/history-latency-20260912`。Astra制定计划并亲读实际diff、SDK/页面调用链和测试日志；执行子代理实际指定`gpt-5.6-terra`。没有push、生产部署、生产造数或手机功能测试。

## 问题、证据及当前结果

| ID | 复现入口/现象 | 根因与证据 | 当前结果 |
| --- | --- | --- | --- |
| H1 | 查找聊天记录→日期，等待十几秒 | RoomPage打开日历后loadCalendarMonth→loadThrough(月初)，按每页60条串行读取本地/远程历史，再将allMessages构造成全文、成员、媒体搜索模型并汇总日期。工作量随当月消息量增长；网络往返和设备解密/投影可能放大等待，不能只归咎于设备或服务器 | 已完成根因与有界timestamp/context架构计划；日期UI和日期定位capability尚未修改。仅完成历史fragment自身游标判断这一前置修复 |
| H2 | 定位旧消息后向下/反复滚动，卡在气泡 | 真实Flutter reverse列表与RoomPage失败用例证明：自动换窗口后anchor.restore调用jumpTo，Flutter因此结束当前用户拖动；迟到旧历史和程序定位还需取消保护 | 已修复并提交bc7ca46a；24项定向通过。用户拖动/惯性中保留窗口，结束后按当前边界/方向换窗；反向拖动取消旧pending/迟到定位；窗口上限200 |
| H3 | 群内大量发送者发出后，本人约50秒才收到 | 当前服务端3小时汇总/messages P95约144ms，send约158ms；没有与事故时刻对齐的日志。sync约30s是正常长轮询等待，不能当成消息延迟。SDK存在每条消息写一次完整历史ID数组的写放大 | 真实SQLite量化已提交27883fa8；尚未证明50秒发生于网络、服务端、设备解密/存储或清理队列。未改密钥队列/数据库事务语义；新增同步阶段计时仍在计划中 |

H2另覆盖：200条极高行的程序定位此前受固定帧次数上限限制；改为有界、自适应已测行高的定位，并保留普通行原有虚拟化步长。该极端fixture不能代表用户实际消息高度或手机帧率。

I0基线核对另发现并修复2096输入：朋友圈好友预览缓存依赖AppHome恢复时配置、全局实例可能跨API/账号复用。9e87c8a0保留2094/2096双方改动，缓存改为API/会话作用域、冷入口自加载、隐私版本/迟到结果隔离；跨组件通知避免build期间setState。13项缓存/真实组件回归和50项contacts/profile合并回归通过。

## 关键文件与提交

- `apps/mobile_flutter/lib/features/matrix/room_page.dart`：活动滚动、延后换窗、反向取消、异步代次、单次预取与无进展判断。
- `apps/mobile_flutter/lib/features/matrix/timeline_scroll_anchor.dart`、`lib/ui/chat/message_scroll_locator.dart`：可取消定位与极高行定位边界。
- `apps/mobile_flutter/test/features/matrix/room_offline_loading_test.dart`、`timeline_scroll_anchor_test.dart`、`test/ui/chat/message_scroll_locator_test.dart`：真实页面、边界拖动、迟到历史和跨帧取消回归。
- `apps/mobile_flutter/third_party/matrix/lib/src/timeline.dart`：af426a3b仅让fragment的canRequestHistory使用自身prevBatch；不再误用live room游标。`CHATFLOW_PATCH.md`记录范围；`sdk_history_fragment_test.dart`覆盖真实getter。
- `apps/mobile_flutter/test/features/matrix/sdk_receive_burst_benchmark_test.dart`：真实MatrixSdkDatabase/FFI SQLite批写、重放去重、重开保持序列的量化测试。
- `apps/mobile_flutter/test/core/session_capsule_recovery_test.dart`：65e94cda清理合入旧fixture的无用import和废弃fake.logout；2项通过。

H1 getter的RED/GREEN由Terra先运行同一命令`flutter test test/features/matrix/sdk_history_fragment_test.dart --no-pub`：RED预期false实际true、exit1，修复后exit0。该代理未保存原始两次日志；Astra没有把代理总结当作独立保留的原始证据。Astra随后运行的44项SDK/adapter/真实RoomPage验证已保存，包含该用例。下一项forward retry未修改，也未声称通过。

## 接收存储量化

| 历史数量 / 新消息发送者数 | 完整ID数组写入次数 | 累计序列化字节 / 最终单份字节 | 最终一轮instrumented action+commit |
| --- | --- | --- | --- |
| 1500 / 50 | 50 | 934395 / 18981 | 21652+9046=30698µs |
| 10000 / 50 | 50 | 6459395 / 129481 | 57501+22085=79586µs |

证据`receive-burst/sdk-receive-burst-test-terra-v5.log`；定向analyze通过。fixture为合成数据、桌面FFI SQLite，计时还包含计数器UTF8测量开销；不是Mi6、SQLCipher、真实Megolm解密或生产50人负载。确认约50次中间写入，不支持声称它单独造成50秒。重放不增加重复ID，重开数据库顺序/集合一致。测试不设易受主机波动影响的性能硬阈值。

## 验证证据与验收限制

所有日志位于[本任务证据目录](artifacts/2026-09-12/history-latency/)。

- H2：`h2-room-anchor-locator-final-terra-v2.log`，24通过；定向analyze通过。原始产品RED为`h2-reverse-anchor-drag-red.log`、`h2-room-page-drag-red-v3.log`和超高行定位RED。held-history fixture最初未滚到边缘的失败是测试设置问题，不算新的产品RED。
- SDK/相邻调用链：`sdk-fragment-final-focused.log`，44通过，包括ACK顺序、撤回持久化、同步代次、adapter及RoomPage；不会因此宣称真实加密设备/双端性能已测。
- 全量与基线失败对比：最终af426a3b源码Flutter2556通过/29失败exit1，29个失败身份与2094基线完全相同，新增0/消失0（`flutter-full-final.log`、`flutter-failure-comparison-final.json`）。输入SHA见`source-final.json`；其余见`candidate-verification.json`、`failure-comparison.json`。移动端边界67通过/3失败，前端161通过/11失败，失败身份与已存2094基线相同；UI契约28组件/364页通过。全仓verify前3个policy/template检查通过，随后缺.env阻断；未导入生产秘密补环境。
- `analyze-final.log`：全量无问题exit0，已清理首次全量发现的两条旧fixture warning。

真机验收由用户执行：旧日期定位后持续双向拖动、边缘松手、旧请求晚到后反拖、引用定位被新手势取消、当前/历史窗口收到新消息、发送后回最新。H2目标是无程序定位抢占手势、无迟到切回、模型≤200；当前没有Mi6帧率/输入延迟定量结论。H1需完成首屏不等待网络与显式日期有界定位后方可验收。H3需关联发送/服务端/sync处理/UI展示时间，并在授权测试环境量化接收P95≤3s目标；目前不能验收为已达到。

## 阻塞与后续顺序

Terra无法继续较大实现批次，拆小后完成了测试警告与单个fragment getter；随后明确表示下一项forward retry测试仍无执行预算。新建指定模型代理被agent thread limit拒绝；本机CLI显式模型只读探测返回401 invalid_api_key，没有任务执行，也没有修改认证或换模型。

ADB最终已发现Mi6被另一路于2026-09-12 23:17:37更新到0.3.87-debug/2099。根main新增6eaf1eb7等红包/转账UI提交，另有未提交app_home/点钻页面修改。本任务候选不能冒充2099完整源码，因此未构建或覆盖安装。已向用户确认另一路是否仍在改动/打包；确认前保留2099。构建脚本已准备，但不等于APK交付。

继续顺序：恢复可用Terra执行→按[计划](../superpowers/plans/2026-09-12-history-latency.md)完成H1 fragment正确性、公开日期capability、实际日历入口→H3本地闭合枚举阶段计时→对齐当时最新版本/源码并做必要回归→按固定签名重建流程生成递增Debug，保留数据安装Mi6。

自动审批曾拒绝删除误建空目录`apps/mobile_flutter/docs/verification/artifacts/2026-09-12/history-latency/`，原因仅为`blocked by policy`。未绕过或继续删除；空目录保留，不影响已提交代码。
