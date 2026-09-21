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

仓库 verify 已通过（退出 0）；两次主动取消及一次缺 .env 的失败不计为通过。Getui 模块两项既有依赖弃用警告仍存在，未修改其依赖。
iOS 原生编译与 iOS 18/26 模拟器检查全部通过。iOS 16.7.16 真机未运行；没有新签名包及生产发布。成功的 Dart 测试不证明受影响手机已恢复历史，也不证明唯一根因。

## iOS 原生编译

源码 `2d46320791f2d51f71b7143a4403acf12a314356`；[CI 35510017099](https://github.com/SuperJJ2333/StarChat/actions/runs/35510017099)，原生 job `106076174840` success。
macOS 15 / Xcode 26.3 / Flutter 3.44.9，命令 `flutter build ios --release --no-codesign`，首次尝试成功；Xcode 编译 178.4 秒，2026-09-20 20:19:10 +08 生成 Runner.app。完整日志 `ios-native-compile.log`。这是未签名编译验证，不是可安装 IPA 或发布。
CI actions/checkout@v4、upload-artifact@v4 有既有 Node 20 弃用提示（runner 使用 Node 24）；不影响本次成功结果，本任务未改工作流版本。

## 仓库门禁

`pwsh -NoProfile -File scripts/verify.ps1` 最终退出 0，日志 `verify-isolated.log`；2026-09-20 20:30 +08 完成。策略、TemplateTools、infra143、Getui28、Matrix bot9、API/Worker2209通过/58环境跳过、mobile70、UI契约32组件375页面、import、AST240、单迁移head/offline升级、OpenAPI、Compose渲染均通过。API/Worker阶段1315.25秒。
隔离 .env 仅取模板的非 BUSINESS 字段，避免导入部署主机地址/生产秘密，检查结束后移除。先前缺少 .env 的失败及两次主动取消均保留日志且不计成功。依赖弃用警告保留在日志中，未以修改无关依赖消除。

## iOS 模拟器与最终边界

同一 CI、同一源码的 iOS 18 job `106076174934` 与 iOS 26 job `106076175066` 均 success，全部工作流通过。iOS 18 完整日志 `ios18.log`：seed 原生测试20项通过、确认旧数据库存在、verify新进程3项通过；iOS26步骤完成证据 `ios26-steps.json`，最终作业汇总 `ios-ci-jobs.json`。这验证模拟器原生媒体/加密历史持久化，不替代 iOS16.7.16 整机重启或企业签名覆盖升级。
最终文档链接、`git diff --check` 通过；独立分支已推送，未合并 main、未签名/发布 IPA，未修改生产。下一步需同签名渠道的覆盖安装候选及受影响设备复验；历史记录物理删除与唯一触发根因仍未由该设备日志确认。
