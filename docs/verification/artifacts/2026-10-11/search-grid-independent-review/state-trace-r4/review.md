# 独立 r4：规范路径消除目录错误，但原等待仍 FAIL

保持 f59 原双解码/HTTP=1/100×100ms真实等待+16ms fake pump 的约束，在 docs 诊断副本仅将 artifacts 根先 `resolveSymbolicLinks()` 后 createTemp。仍使用 r3 两个 synthetic gated 阶段trace，finally最前额外原 `_settle` 仅供诊断；原运行时文件在 finally 中严格还原，原测试从未修改。

结果仍 FAIL（不是候选门禁）。与 r3 相比，真正出现 **两次 persist-done / 零 persist-error**，说明规范化根确实移除了目录枚举错误。但第二次 persist-done 出现在 `BEFORE_DECODE_ASSERT(decoded=1, HTTP=1, budget/scheduler=0)`、`TEST_FINALLY_START` 之后，`TEST_FINALLY_EXTRA_SETTLE_DONE` 之前；第二个consumer在断言前已persist-start，尚未完成。路径修正只关闭目录错误，不足以关闭原等待失败。

不可据此增加超时、把双消费者要求改成单消费者，或将诊断最终完成计作候选PASS。下一步由作者定位 `_write` 的具体 await 或测试 fake clock/real-I/O 驱动差异。额外settle能完成排除永久丢通知，但不证明真机存在/不存在对应卡顿。源码恢复 SHA/时刻/命令/退出码和诊断副本SHA见 receipt；补丁和日志按 manifest 保留。临时 Dart 副本已删除，仅保留可重建patch。
