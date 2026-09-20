# iOS 重启会话修复验证（2026-09-20）

基线 `83c2f196`；分支 `codex/ios-reboot-session-20260920`。Windows / Flutter 3.44.9 / Dart 3.12.2。用户批准的实现范围见[计划](../superpowers/plans/2026-09-20-ios-reboot-session.md)。

证据目录：`artifacts/2026-09-20/ios-reboot-session/`（本地忽略目录）。

| 检查 | 实际结果 | 日志 |
| --- | --- | --- |
| 安装保护、目录不确定、会话保留 | 5 项预期失败后转绿 | root-red.log / root-green.log |
| 启动重试与只读预检 | 失败后通过；其中新接口缺失为编译红灯 | root-retry-red.log / root-green.log |
| 同身份恢复 | 新接口编译红灯后 22 项通过 | root-restore-red.log / root-restore-green.log |
| 恢复部分成功后重试 | 1 项行为红灯后 26 项通过 | pending-restore-red.log / pending-restore-green.log |
| 退出后迟到的异常 | 1 项行为红灯后 27 项通过 | late-failure-red.log / late-failure-green.log |
| 错误分类、真实原生错误、身份校验 | 专项红绿通过 | login-*.log |
| 最终 Flutter 全量 | 退出 0，3681 passed，2:35 | flutter-final.log |
| flutter analyze | 退出 0，No issues found | analyze-final.log |
| 独立规格审查 | 通过；恢复 pending、错误分类建议已修复 | spec_review 子代理审查 |
| 独立质量/安全审查 | 通过；退出后迟到异常清理建议已修复 | security_review 子代理审查 |

全量命令为 `flutter test --reporter compact`；静态检查为 `flutter analyze`。源码输入 hash 另存证据目录；初始输入为 baseline-input-hashes.json。最终全量后仅修正测试的花括号格式，未改变生产源码或断言行为。

仓库 verify 尚在执行；两次主动取消及一次缺 .env 的失败不计为通过。Getui 模块两项既有依赖弃用警告仍存在，未修改其依赖。
iOS 原生编译/模拟器检查待记录。iOS 16.7.16 真机未运行；没有新签名包及生产发布。成功的 Dart 测试不证明受影响手机已恢复历史，也不证明唯一根因。
