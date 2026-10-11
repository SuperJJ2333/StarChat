# f59 独立诊断补充：source 已完成，单消费者在清理后才完成

此前 [REJECT](review.md) 保持有效。root 明确授权必要可逆诊断后，在独立树临时应用作者固定 14 行 `contain_image_bubble.dart` 状态 trace；只打印合成事件 key 和状态，宏 `SEARCH_MEDIA_DIAGNOSTICS=true` 才启用。每次 try/finally 还原原源码，前后 SHA 均为 `485f15b5370d4575adc391b48477139ed170d5d51ca8e0fdf6353ea001eb3477`；Git mobile diff 为空。诊断源码 SHA 为 `06d90e54ff578b52d9b6b99761416db81519e6df96e708bb03d9d5d5021ddcd7`，patch SHA `b6aa6f88380877e0a1f6805f1c1ca0871ad0fe9d39402459414499b2a8fa4b10`。这些执行不是候选门禁。

- [r1 receipt](state-trace-r1/receipt.json) / [log](state-trace-r1/state-trace.log)：精确原 f59 test + 临时状态 trace，仅 current image。新增 decoded=2 断言仍 FAIL。两个 load-complete 都出现在框架错误报告前，单凭这个顺序不能证明回调早于原断言；错误报告可能在 finally 后才打印。
- [r2 receipt](state-trace-r2/receipt.json) / [log](state-trace-r2/state-trace.log)：相同临时状态 trace，另以 docs 测试副本加入断言前/清理开始两个明确里程碑以及公开预算/调度计数。**old-image load-complete68 → BEFORE_DECODE_ASSERT(decoded=1, budgetBytes=0, budgetQueued=0, schedulerActive=0, schedulerConsumers=0, HTTP=1) → TEST_FINALLY_START → neighbor load-complete68**。故至少一条消费者后续 future 在断言时尚未完成，即使源下载/预算/调度已结束；此次未完成对象反转为 neighbor，不能认定某固定 event 的布局故障。

r2 不支持“只是第二个气泡不可见”“只是等待 source 还未下载”“两个回调在失败报告前出现所以原断言应通过”这些解释。具体停点仍需作者沿消费者后续引用持久化/结果分发链定位，不从该证据推导真机出现率、主线程时延或确定根因。独立原文件 RED 仍保留，不更改 HTTP=1 或双消费者要求。

[作者状态 patch](state-trace-r1/bubble-state-diagnostic.patch) 和 [r2 里程碑 patch](state-trace-r2/milestone-probe.patch) 可重建本次诊断；docs 测试副本已删除。原 test/source 严格还原，测试 input 与所有日志、回执哈希在 [补充清单](diagnostic-manifest.json)。首轮报告、完整失败日志及其清单未改。
