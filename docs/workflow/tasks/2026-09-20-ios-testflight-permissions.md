# iOS TestFlight 权限修复测试包

用户授权权限修复、TestFlight构建与测试分发，明确不用企业签名。计划：[执行计划](../../superpowers/plans/2026-09-20-ios-testflight-permissions.md)。
工作树.worktrees/ios-reboot-session，分支codex/ios-testflight-permissions-20260920，整合基线56480ba2。2026-09-20 23:12+08继续执行；此前精确启动时间未知。
已确认GitHub签名及ASC秘密名称存在；最近ios-testflight运行35509514613是Flutter checks失败，签名上传未执行。现有工作流另有profile来源错误，准备复用已成功的ios-0353签名实现。
下一步：权限TDD、签名/ASC预检、测试、构建上传。当前无新IPA或TestFlight安装成功证据。
