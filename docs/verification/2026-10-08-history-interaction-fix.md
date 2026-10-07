# 大历史会话交互修复交付记录

源码修复及可用自动化门禁完成，候选commit `3c37b52960ab79b46566fb16d84fab280b34a7c2`，分支 `codex/history-interaction-fix`。正式Android仍为0.4.35+2204、发布源3a620495；本轮没有更新version/build、安装、生产发布或更新弹窗。本记录不承诺所有手机或无限历史量的实际帧耗时。

## 修复行为

- 房间ID顺序从整片段JSON改为增量索引、计数与有界分页；就绪房间不在普通进入、刷新、输入法/房间切换时读写或解码全房间ID。一次性旧库转换在worker中通过SQLCipher blob分块读取，每个ACK/提交最多256条；旧源及正文保留。显式旧格式导出/回退的最终整行激活是独立的O(N)维护操作，不能算普通交互路径。
- SDK常驻已确认消息最多1000条，待发消息独立保留；界面初始40/最多200条。未改变的revision复用投影，变化、双向翻页、过滤页、搜索/日期及聚合按页推进；历史正文仍在加密磁盘中，可继续向前/向后读取。
- 自动/手动重试保留原插入时间和txid，首次Matrix权威sync按其连续顺序校正。恢复正文/checkpoint与独立RECOVERY顺序原子提交，不把缺少连续性证据的旧记录拼进当前聊天窗口，不按时间强行排序跨间隙历史。
- 快滑时用`correctBy`同时重基布局和惯性模拟；锚点测量保留整行间距，已读/mention仍按正文可见性判断。迟到分页、解密、搜索、语音及房间切换结果受generation/owner校验，取消的搜索句柄及时释放。

Matrix加密、SQLCipher密钥所有权、金融、身份/权限及服务器边界未改变。没有清空账号、聊天数据库或卸载应用。

## 验证与输入身份

| 门禁 | 实际结果 | 证据 |
| --- | --- | --- |
| 最终全量Flutter | exit0；5632PASS、9既有诊断opt-in skip；425.848787秒；1424输入前后/当前一致 | [metadata](artifacts/2026-10-08/history-interaction-fix/root-gates/flutter-shared-full-final-v2.json) |
| 格式/静态分析 | 44 Dart零格式变更；应用及11项vendor库分析0问题 | [format](artifacts/2026-10-08/history-interaction-fix/root-gates/candidate-final-format-v2.json)、[app](artifacts/2026-10-08/history-interaction-fix/root-gates/app-analyze-final-v2.json)、[vendor](artifacts/2026-10-08/history-interaction-fix/root-gates/vendor-analyze-final-v2.json) |
| 移动Python/UI | 354PASS/1既有Ruby skip；34组件535页契约PASS | [Python](artifacts/2026-10-08/history-interaction-fix/root-gates/mobile-python-final-v2.json)、[UI](artifacts/2026-10-08/history-interaction-fix/root-gates/ui-contract-final-v2.json) |
| Android原生 | ARM64 standard profile编译exit0；178.0830532秒；1476输入稳定；新APK六个key/blob接口存在 | [build](artifacts/2026-10-08/history-interaction-fix/native-preparation/android-arm64-profile-final-v2/result.json)、[exports](artifacts/2026-10-08/history-interaction-fix/native-preparation/android-arm64-profile-final-v2/sqlcipher-exports.json) |
| 有序独立审查 | SPEC→QUALITY产品接受；无未解决P0/P1/P2；独立证据身份复核 | [SPEC](artifacts/2026-10-08/history-interaction-fix/final-spec-v2/final-review.md)、[QUALITY](artifacts/2026-10-08/history-interaction-fix/final-quality-v2/final-review.md)、[证据](artifacts/2026-10-08/history-interaction-fix/final-evidence-v2/final-audit.md) |

真实SDK/SQLite及RoomPage回归覆盖1k/10k/100k历史的工作量预算、键盘0/160/320 inset和输入selection、分页/同步未完成时A→B→A切房间、持续drag/ballistic、padding-only已读负/正控制。真实数据库检查4500条已确认消息的所有ID/正文在关闭重开后完整，pending独立核对；迁移专项达到250k并验证分块上限与yield。计数、排序和事务覆盖保留原断言。

首轮全量exit1/46FAIL保留为返工证据，暴露真实批内读写一致及恢复索引接口缺口和旧fixture假设；修正后以完整当前源码重跑，不用旧局部门禁冒充最终通过。`final-source-commit-binding.json`将原测试parent d9abd7ba与46项精确输入映射到上述新commit，提交没有改变已测源码。依赖保持原锁定版本/URL/hash，只将原有ffi2.2.0、sqlite3 2.9.4声明为直接依赖；官方pub.dev `pub get --enforce-lockfile`通过。

工具：Windows10.19045、PowerShell7.6.5、Flutter3.44.9/Dart3.12.2、JDK17.0.20、NDK28.2.13676358；具体命令、起止、锁SHA、OS与日志SHA见metadata。原有仓库/部署/模板门禁的输入未变，按[复用证据](artifacts/2026-10-08/history-interaction-fix/root-gates/reused-policy-gates-final-v2.json)复用。没有重新启动等价已完成门禁。

## 明确边界与恢复入口

Android中间APK SHA `a7d81ad71794c8fcb979705d4aaef440bcfa248069d70d8eb3c49a57827b5fae`、95527985bytes，只用于原生编译/ABI检查；未按正式交付重建、固定签名及分发流程生成新成品。编译有现有12插件的KGP未来迁移及Java过时/unchecked提示，已保留日志；该任务没有升级插件或更改Java源。

ADB无设备，用户回复暂时无法USB连接；手机键盘、快滑、切房间的实际帧耗时尚未测量。没有Mac/iOS runner；既有Ruby/iOS hook检查跳过。全仓`verify.ps1`预检缺root `.env`，聚合未执行，未导入生产秘密；相关移动门禁已独立执行。这些不是通过项。

下一步正式交付必须先选择未占用的新版本/build，按[Android固定打包流程](../runbooks/android-apk-rebuild.md)生成并验证成品；真机可用时补充profile。旧正式2204仍不含本次修复。恢复先读[本任务台账](../workflow/tasks/2026-10-08-history-interaction-fix.md)及[计划](../superpowers/plans/2026-10-08-history-interaction-fix.md)，保留primary原有WIP、历史索引尾部及本轮源码/证据身份。
