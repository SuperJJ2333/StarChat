# R7c 启动安全壳候选

用户授权继续修复和自行决定产品调整。执行已批准即时通讯可靠性计划 R7c；root 独占 `installation_startup_gate.dart`、`main.dart` 与对应启动测试，未打开或清理用户数据库。本候选待独立规格/领域与质量安全审查、共享客户端门禁及成品验证。

原门禁无期限 deferFirstFrame；另外版本/SharedPreferences 的 await 在 runApp 之前，门禁本身无法覆盖。新入口立即安装唯一门禁，将版本/偏好初始化纳入同一计时；1 秒后显示无账号内容的等待壳，3 秒仍等待则显示设置、安装检查或本地聊天初始化的实际阶段。未完成 Future 保持单次执行，不提供会重复打开数据库的重试。明确失败之后才允许重试，完成的偏好准备不重复执行；迟到完成和 dispose 保持原安全边界。短启动仍直接显示就绪内容。

本次同时修正首帧埋点：deferFirstFrame 期间仅布局的帧不计为可见首帧；在允许向 engine 提交后才结束首帧 trace。这是 Flutter 提交帧指标，不声称 GPU 呈现或真实手机冷启动耗时。

证据位于 `artifacts/2026-10-11/im-reliability-implementation/`：

| 门禁 | 结果 | 文件 |
| --- | --- | --- |
| 原门禁 reconcile/start 长等待 | 2 项行为 RED，7 项原/相邻通过 | r7c-red.txt |
| 原 HEAD main + 真实 app.main、挂起 PackageInfo | RED：runApp 尚未执行，returned=false | r7c-entry-red.txt |
| 新门禁/真实入口/主题/诊断/本地客户端恢复 | 40 PASS，exit0 | r7c-regression.txt |
| 延迟首帧指标 | RED：不可见布局过早生成 PerformanceRecord；同一测试在最终 40 项中通过 | r7c-trace-red.txt |
| 最终 5 个 Dart 文件 analyze | 无问题，exit0 | r7c-analyze.txt |

Flutter 路径 `C:/src/flutter/bin`；PowerShell7/UTF8，pub.dev offline enforce-lockfile；没有依赖锁变化。专项包含总预算不重置、短启动、挂起操作、准备失败、重复点击、生命周期恢复、迟到完成、销毁、失败脱敏和首帧单次记录。新插件等待测试调用真实 app.main，原文件通过 Git HEAD 获取，验证后 finally 恢复候选，未污染其他工作树。

测试使用注入 Future 和 Flutter 测试时钟；1 秒/3 秒是调度预算，不能保证 UI 线程本身阻塞时仍按时绘制。数据库打开性能、iOS protected data 与真实冷温热启动需绑定最终安装包/设备 profile 继续验证。没有 APK/IPA 构建或分发。共享 verify 仍由主任务统一安排，缺 `.env` 的环境限制未伪装为完整脚本通过。

实施与专项测试约 2026-10-11 11:18–11:26 UTC+08；单步起止未完整采集，准确工具耗时见日志。后续步骤：双审→集成客户端门禁→固定签名成品/设备验收。
