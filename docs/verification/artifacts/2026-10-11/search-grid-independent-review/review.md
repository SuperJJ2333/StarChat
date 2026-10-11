# f59cf233 搜索媒体网格独立评审：REJECT

对象：`f59cf233b22a827723db47784eaaa5df45f4eefc`；基线：`5988deb48185f4f2fb0743615f17ccea597671ce`。独立 checkout：`im-media-cache-review/StarChat`，分支 `codex/im-search-grid-independent-review`。未修改作者树、root、生产或原测试/运行时代码，未占用 W/V。

## 1. 规格与域边界（先执行）

已核对根/Flutter AGENTS、mobile-delivery-workflow、批准的 IM 修复方案中取消/账号代际/E2EE边界，并阅读实际 cache publication、消费者生命周期及诊断 patch。提交中除 docs 外仅一个测试文件变化：新增 `ContainImageBubble` import 与导航前有界等待/断言。原搜索后 HTTP count=1、当前窗口不变、异账号拒绝、隐藏/撤权/销毁/懒加载/画廊要求均未删除。运行时 lib Git tree 保持 `88e982c36178b7d9096c581de199e27f6a34febf`；未改 native、依赖、协议、加密或金融状态。

作者诊断证据确实显示两个初始消费者共享一次 HTTP，固定 settle 后先导航导致最后消费者取消，再因 publication guard 拒绝缓存而产生后续第二次请求。以实际初始解码为缓存复用前提在语义上合理，不能把原期望改成 2，也不能允许无消费者的迟到结果发布。然而新增“两气泡都解码”的前提在独立运行中未成立，故规格整体尚不可验收。域边界静态检查通过不等于本测试修正通过。

## 2. 质量与安全（后执行）

**P1 / 阻断该 test-only 提交集成：新增断言仍失败。** 独立完整文件命令未指定场景过滤器：

```text
flutter test --no-pub test/features/matrix/room_search_media_grid_test.dart --reporter expanded
```

实际 2026-10-11T09:01:28.5076488Z 至 09:01:52.2576951Z，23.7500463 秒（含工具启动），exit 1。第一个 `current image` 场景在 line 316：expected decoded images 2 / actual 1。Flutter 计数为 0 PASS / 1 FAIL；文件内十个场景属于一个 widget test，后续九个场景未完成，不能宣称十项已验收。见 [原始日志](full-file.log)、[执行回执](full-file-receipt.json)。

进一步仅在 docs 下复制测试加入公开 widget/render 几何诊断，原测试及 runtime 未改。诊断副本两次运行均重复 decoded=1、HTTP=1。最终几何证据：

| 项目 | old-image | current-neighbor |
| --- | --- | --- |
| widget 存在 | 是 | 是 |
| RawImage | 0（占位图，无失败按钮） | 1（1×1 解码） |
| 全局 bounds | (60,464)-(61,465) | (60,401)-(61,402) |
| viewport | (0,44)-(800,520) | (0,44)-(800,520) |
| ticker / route current | true / true | true / true |
| defer / initial / scrolling | false / null / false | false / null / false |

默认 view 为 physical 2400×1800、DPR 3；未修改 view。两者在屏幕和视口内，故不能将该失败解释为第二个气泡在屏外，也不能仅延长等待或缩减到一个解码断言。当前证据指向初始消费者完成/通知链路需要进一步定位，尚不足以断言具体根因或生产重现率。package_config 与作者树逐字段完全相同，pubspec.lock 归一化文本相同。

诊断见 [首个观察](visibility-probe.log)、[完整几何](geometry-probe.log)、[可重建补丁](geometry-probe.patch)。两次诊断脚本类型转换编译失败分别保留，随后只修正 docs 副本中的 RenderBox cast；这些失败不是产品测试结果。副本执行完已移除，仅保留补丁，避免多余测试被误执行。

[身份审计](identity-audit.json) 17 PASS / 0 FAIL：唯一 test-only diff、全部五个作者源码身份、七份作者证据 LF 哈希、原 root 完整失败日志 raw SHA，以及原 HTTP 断言/无运行时临时埋点。独立 Git checkout 的七个日志为 CRLF，与作者 raw SHA 不同；按明确记录的 LF SHA 校验通过，未把归一化值冒充原始字节哈希。自身证据由本目录 `.gitattributes` 保留原字节，并由 [证据清单](evidence-manifest.json) 绑定。

## 结论与下一步

**REJECT。** 无源码安全边界退化，但独立完整测试未通过；作者 29 PASS 的既有日志不能覆盖此次独立 RED。原 root 的 5957 PASS / 9 SKIP / 1 FAIL 完整门禁仍是失败记录。将可见气泡未解码的诊断交回作者，修正后在新精确候选上独立重跑完整文件，保持两个消费者和搜索后的 HTTP=1 约束；本次不重复作者完整 29 项。未运行/声称整仓通过、APK成品通过、生产发布或真机性能通过。
