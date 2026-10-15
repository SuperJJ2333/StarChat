# iOS 0.4.46+2215待签名IPA

- 用户授权：打包iOS v0.4.46，交用户签名后回传分发；确保检查后台通知链路。用户确认沿用现有推送身份。本阶段不发布正式包。
- 计划：[签名交接](../../superpowers/plans/2026-10-15-ios2215-signing-handoff.md)。root拥有CI增量/契约与本文；产品源码暂未改变。
- 工作树：C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat；分支codex/ios-history-ipa-2215-20261015，基线ea9b52a4。主目录历史未提交内容保留。
- 版本：0.4.46+2215，com.liuhetong.liuhetongMobile，生产APNs Team HY9Q7Q35S5。最终回签权益及真机到达待验。
- 状态：构建准备。新增原生通知门禁RED1/PASS1，待GREEN与macOS执行。移动源码相对5e1ad763无差异；5965共享测试/9skip/analyze及401边界既有证据仅在输入一致时复用。
- 证据目录：docs/verification/artifacts/2026-10-15/ios2215-signing/。
- 服务器只读初检：Sygnal生产APNs app_id/topic/Team匹配，密钥存在；VoIP网关healthy。未取出私钥/完整设备token，未发送测试推送。配置存在不等于APNs已接受或手机展示。
- 下一步：冻结候选、审查、触发unsigned CI；并行独立核验通知链路。开始精确时间未记录，以后续CI/命令receipt为准。
