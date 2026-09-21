# iOS 权限修复与 TestFlight 测试交付计划

用户已接受权限修复建议并要求构建测试版本、改用TestFlight安装，后续明确要求继续。授权包含修复、构建、TestFlight上传；不改生产更新弹窗、不发企业包或App Store正式版。

实现基线：56480ba2，独立分支codex/ios-testflight-permissions-20260920，复用.worktrees/ios-reboot-session。已整合060097ef main和已批准/审查通过的2d463207会话修复；文档索引冲突保留双方条目。

设计：启用实际使用的相机/麦克风/相册/相册写入/通知插件编译开关，保留原权限声明。处理请求后的永久拒绝并跳系统设置。以Apple Distribution release构建承载测试（TestFlight不使用Flutter debug/JIT），关闭企业更新入口，保留原Bundle ID及加密/推送配置。现有CI有签名资产，使用IOS_PROFILE_BASE64而非名称解码，签名/身份/原生权限能力验证后上传。版本根据Apple已有build预检确认，不能覆盖旧build。

- [x] 权限TDD：真实平台通道状态与请求结果回归，Pod配置及原生二进制能力门禁；实现最小修复。
- [x] TestFlight：修正并复用已成功的ios-0353签名步骤，提前检查profile与ASC访问/版本；仅测试分发，无企业产物任务。
- [x] 专项、analyze、Flutter全量及适用verify（同源未改后端证据可复用）；规格后质量安全审查。
- [ ] 固定来源并运行CI，验证签名、权限实现、上传、Apple处理状态与测试安装入口。设备授权弹窗、整机重启待用户设备验收。

所有权：权限代理仅Podfile、call_permission_readiness及其测试/权限门禁；root拥有工作流/签名上传脚本/版本/文档；审查只读。禁止秘密进Git或日志，不改变Bundle ID绕过签名问题，不卸载/清除设备数据。

2026-09-21 02:43+08：第四项的签名、权限实现、上传、Apple VALID已完成；内部测试可用性被MISSING_EXPORT_COMPLIANCE阻断，待用户确认实际申报信息。不得重建同包或伪造加密声明。
