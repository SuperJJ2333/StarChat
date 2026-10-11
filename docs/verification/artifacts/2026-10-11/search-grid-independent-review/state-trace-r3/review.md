# 独立 r3：预览持久化受 Windows 非规范长路径影响

本轮仍以 f59 原断言为对象，候选门禁状态仍为 REJECT。除前次 bubble 14 行 synthetic trace 外，临时加入作者 room_image_preview_cache 阶段/异常 trace，并在 docs 测试副本 finally 最前添加一次原 `_settle`（40次真实25ms+fake16ms）。其目的是观察可见状态下后续完成，不放宽原断言，也不能据清理后完成声称断言通过。

实际链路见 `phase-trace.log`：两 source-done、两 persist-start，**零 persist-done**。old-image 的 persist-error 是 `Directory.list` / `PathNotFoundException` / errno3，完整合成路径含 `apps/mobile_flutter/../../docs/.../emoji-previews-v1/<hash>/*`。异常被现有 catch 消化，old 继续 memory/session/load-complete。断言前 decoded1、HTTP1，预算/调度全0；finally开始后的额外settle内，neighbor 的同类 persist-error 返回，随后 memory/session/load-complete，之后才 EXTRA_SETTLE_DONE。因此并非永久丢通知，具体失败位于持久化目录枚举而非内存/会话阶段。此前“单消费者延后”观察正确，但不再据此怀疑独立运行时通知丢失。

作者独立长路径/短路径观察不计作本评审的验收结果。下一步只在相同原 RED checkout 规范化 fixture 的临时目录根，验证两 persist-done/零 persist-error、两初始解码及前后 HTTP1。原等待上限、账户/可见性/撤权/搜索断言保持。该测试环境故障不得表述成 Android/iOS 已证实生产异常或百分比。

原作者阶段 patch 为 CRLF，首次 `git apply --check` 未通过且未修改源码；原字节保存为 preview-phase-author-raw.patch，明确 LF 规范化后保存为 preview-phase-diagnostic.patch 并成功应用。两运行时文件均已由 finally 还原，receipt记录前/patch后/restore SHA，原test未改。临时 docs Dart 副本已移除，保留重建patch。
