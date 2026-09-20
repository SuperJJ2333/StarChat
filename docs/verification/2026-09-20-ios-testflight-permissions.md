# iOS 0.3.103 / 2145 TestFlight 交付证据

- 来源：2de62b75bd5f01b2c4268f875984f61b94a65233，独立分支codex/ios-testflight-permissions-20260920。
- 构建：[35528706992](https://github.com/SuperJJ2333/StarChat/actions/runs/35528706992)。Apple Distribution / App Store Connect；不是企业签名。TestFlight使用Release构建承载测试。
- IPA SHA256：`4fdef120e186630032066d8a4110092b81c506849291a27907d3cc5626e27855`。
- 已验证产物：[ChatFlow-iOS-signed](https://github.com/SuperJJ2333/StarChat/actions/runs/35528706992/artifacts/10610573233)，保留14天。未重复回拉整包。
- 02:30+08最终IPA签名、生产APNs、SQLCipher、版本、iPad及权限运行时方法表通过；02:32上传成功。[日志](artifacts/2026-09-20/ios-testflight-permissions/final-signed-ci.log)。工作流整体failure来自Apple首次查询窗口exit75，不能称整轮通过。
- 02:43+08 Apple build ID `b6ac0d45-b5d4-41f8-a852-e9cda0dacbde`，VALID、expired=false，内部MISSING_EXPORT_COMPLIANCE。[Apple状态](artifacts/2026-09-20/ios-testflight-permissions/apple-status-3.log)。内部TEST组目标`6c3548a1-b45d-41c7-b4b1-e7a567d15081`；尚未确认可安装。
- 测试：Flutter3701、权限专项29、analyze0；同源原生成功job106120745319复用经过完整输入比较。最终IPA证明原生权限实现已编入；不替代真机相机/相册首次弹窗验收。后端verify同源未改，复用API2209/58环境跳过记录。
- 旧2144真实二进制中相关权限策略方法表为空，新包运行时方法表门禁通过。Pod缺失宏是权限问题证据；此前重启修复未进入2144，不能归因于该修复删除权限。
- 尚需：完成实际加密出口合规申报、内部组关联读回；iOS16.7.16相机/录音/通话/系统设置跳转与整机重启验收。没有设备历史数据已恢复的证据。

详见[任务与阶段计时](../workflow/tasks/2026-09-20-ios-testflight-permissions.md)。
