# 搜索媒体网格最终独立评审：PASS（test-only 修正）

审查对象 `f186d0e43b88da4d6a77397711ebcac9f560b614`，基线 `5988deb48185f4f2fb0743615f17ccea597671ce`，test-only 前置提交 `f59cf233b22a827723db47784eaaa5df45f4eefc`。独立树 `im-media-cache-review/StarChat` 与首次稳定 RED 相同，分支 `codex/im-search-grid-final-review`。未修改作者/root/生产，未使用 W/V/T。此结果只验收该测试修正，不代替 root 最终共享门禁、APK或设备验收。

## SPEC / domain：PASS（先审查）

完整非 docs 差异只有 `apps/mobile_flutter/test/features/matrix/room_search_media_grid_test.dart`。运行时 lib tree 严格保持 `88e982c36178b7d9096c581de199e27f6a34febf`，native、依赖、协议、E2EE/金融/账号代际/取消 publication 行为没有修改。

修正仅使 fixture 的临时目录先解析成规范绝对路径，并把原来的 100 次“真实100ms+fake16ms”推进换成**相同10秒真实 Stopwatch 截止**内的“真实16ms+fake16ms”推进。两当前气泡必须解码为2、导航前源 HTTP=1、搜索后 HTTP=1，均保持严格断言。原当前窗口一致性、旧图/旧视频、隐藏/销毁/撤权/异账号拒绝、重试、懒加载与gallery语义均保持；未加skip、吞异常、改期待计数或延长真实期限。临时目录仍在已有 docs/verification 路径下。

这关闭两个 fixture 前提缺陷：非规范长 Windows 路径使持久化 Directory.list 错误被可选缓存兜底掩盖；固定100个pump不能证明真实I/O链已完成。旧 f59 独立 RED，以及 canonical-only r4 仍失败的证据保留在原独立报告提交 e0bfd5f4、fe01254a、65ee27cb、bc504cac，未重写为通过。

## QUALITY / security：PASS（后执行）

先在原 RED 环境，以相同候选 + 临时 synthetic gated 状态/阶段 trace + docs 测试副本作辨别验证，实际 exit0。两次 `persist-done` 都在 `BEFORE_DECODE_ASSERT` 前，零 `persist-error`，decoded=2、HTTP=1；实测等待 **2016ms / 105 pumps / fake1680ms**。本次超过旧100pump上限，支持旧 fixture 的推进次数限制不能作为已完成证明；它不是手机性能测试。两临时runtime源码在 finally 按原字节还原，之后逐字节与 f186 Git blob 对比一致，原 test 从未改变。见 [诊断日志](phase-trace.log)、[诊断回执](phase-receipt.json)、[重建副本补丁](phase-probe.patch)。诊断不计作最终无trace候选门禁。

随后对精确 f186 无trace、无selector独立运行完整文件：

```text
flutter test --no-pub test/features/matrix/room_search_media_grid_test.dart --reporter expanded
```

时间 `2026-10-11T09:40:56.0209468Z` → `2026-10-11T09:43:09.6801061Z`，墙钟 `133.659` 秒（含工具启动），exit0；Flutter **1 PASS / 0 FAIL**，内部十个场景全部完成。初始等待 **2053ms / 104 pumps / fake1664ms**，双气泡解码、前后HTTP1均通过。十场景是一个widget test，诊断/作者重复运行不叠加成独立测试数量。见 [无trace完整日志](full-file.log)、[回执](full-file-receipt.json)。

[身份审计](identity-audit.json) **23 PASS / 0 FAIL**，包括唯一test-only差异、完整runtime tree、作者3个源码及16份证据身份、严格断言和临时trace恢复。作者三份receipt有Windows CRLF表示差异，使用其明确提供的LF SHA核对，并同时记录本地raw/Git blob SHA；未将归一化值伪称原始字节。作者同输入 changed-file analyzer 0 issues 证据已查验精确身份，未重复运行。此前五文件29项相邻检查仅按未变化输入复用，不用它覆盖本次失败/通过结论，也不叠加测试计数。

## 验收范围与下一步

该 test-only 修正可集成；保持原 root 完整门禁 5957 PASS / 9 SKIP / 1 FAIL 的历史失败身份，后续由 root 对最终组合候选运行完整共享门禁。不能从本报告宣称整仓/Android成品/iOS真机/生产已通过。所有本次运行代码已恢复为候选，临时 docs Dart 副本已移除，日志/回执/patch的原始字节由 [清单](evidence-manifest.json) 与 `.gitattributes` 绑定。
