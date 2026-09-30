# 管理员提现设计文档校验

- 日期/时间：2026-09-30T18:03:39+08:00；Windows，pwsh.exe，UTF-8 无 BOM。
- 输入：本任务 design、ADR、plan、workflow task 四个新 Markdown 文件。
- 校验：Python 读取 UTF-8，解析相对 Markdown 链接并断言文件存在；禁止 TODO/TBD/FIXME；W1–W6 验收与 Task 0–5 覆盖检查；Decimal ROUND_HALF_UP 校验 200/7=28.571429、200/7.35=27.210884。
- 结果：四份文件校验及公式/覆盖检查 PASS，命令退出码 0。`git diff --check` 退出码 0；既有 pubspec.lock 的换行警告属于其他工作区改动，本任务不修改或提交。
- 自查：按钮调整的是基准汇率；已签名也不能进入 VOIDED 捷径；充值共享鉴权不被收紧；旧客服领取历史保留；迟到到账不被停止复核阻断；取消不触发全局恢复。
- 修改范围：文档五份，无产品源码、无配置、无生产/资金写入。本阶段不运行产品测试、不声称实现通过。
- 文档审批、Domain 与 Quality/Security 独立评审尚未完成；不是上线验收证据。
- 起始准确时间未采集；不估算阶段耗时。下一步用户审阅文档及选择执行方式，按计划 Task 0 开始评审。

- 提交前的 staged whitespace 检查发现两处 Markdown 换行尾空格，已移除；修正后对全部新增文件重新检查通过。
