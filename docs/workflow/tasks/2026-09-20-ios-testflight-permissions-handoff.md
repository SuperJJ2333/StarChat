# iOS TestFlight 内部测试交接

本任务在独立工作树`.worktrees/ios-reboot-session`、分支`codex/ios-testflight-permissions-20260920`执行，未合并其他任务的main变更。完整[任务台账](../../../.worktrees/ios-reboot-session/docs/workflow/tasks/2026-09-20-ios-testflight-permissions.md)和[交付证据](../../../.worktrees/ios-reboot-session/docs/verification/2026-09-20-ios-testflight-permissions.md)在该工作树。

0.3.103/2145已构建、验证签名和权限实现，并于2026-09-21 02:32+08成功上传App Store Connect。Apple于02:43返回VALID、未过期，但MISSING_EXPORT_COMPLIANCE，尚未确认内部可安装。用户明确选择已有内部测试邀请，并答复“我在 App Store Connect 完成申报后告诉你”。等待该确认；不自行填加密声明。

源码2de62b75bd5f01b2c4268f875984f61b94a65233，IPA SHA256 `4fdef120e186630032066d8a4110092b81c506849291a27907d3cc5626e27855`，[构建与上传](https://github.com/SuperJJ2333/StarChat/actions/runs/35528706992)。含重启会话保护及权限宏/设置跳转修复。该run整体failure来自Apple查询等待exit75，不能表述全部CI成功。原生与全量测试的精确复用证据见完整台账。

收到申报完成确认后，继续现有ios-testflight.yml，inputs `distribute-only=true`、`build-number=2145`；核验VALID、未过期、内部READY_FOR_BETA_TESTING或IN_BETA_TESTING，并关联/读回既有内部TEST组6c3548a1-b45d-41c7-b4b1-e7a567d15081。禁止重建或重复上传同包；不要改企业渠道或生产更新设置。真机相机/录音/通话/设置跳转及iOS16.7.16整机重启待验收。
