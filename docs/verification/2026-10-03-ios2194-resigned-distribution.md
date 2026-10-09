# iOS2194 新回签分发验收

2026-10-03 15:59 +08：用户提供 `(14) (1).ipa` 并对披露的同版本、新企业身份和三项注入明确回复“接受，直接分发此包”。当前精确包已分发。

- 最终 `0.4.25/2194`，61,709,960 bytes，SHA256 `d532f913dde2f6e1346b16c2a84633ee6257400a799a898b10cd446d0bc07cda`；CI原始SHA `a2f7db096df422c87ab472869909a073c38c8144729b2d1d049e7f7cca3ab6d1`。
- Team `4Z6MTB864G`，实际App ID `4Z6MTB864G.com.cigna.mobile.IOHspark.enterprise`，Keychain `4Z6MTB864G.*`/`com.apple.token`。生产APNs、企业分发、get-task-allow false，profile未过期。19个CMS签名及页hash通过；未验证Apple设备信任/证书链或覆盖升级。
- 标准身份门禁退出1；非签名内容比对退出1：ATHelper.dylib、flag、Runner加载命令。特批只绑定本次双SHA及身份，不修改通用门禁。
- 新包不可变URL：[IPA](https://www.liuhetong888.com/downloads/ios/ChatFlow-0.4.25-2194-enterprise-d532f913.ipa)；[安装页](https://www.liuhetong888.com/download?platform=ios&install=1)。download.html与manifest URL已更新；旧SHA552a07a4包保留、HEAD61709705通过。
- `IOS_RESIGN_PREFLIGHT_PASS` / `IOS_RESIGN_PUBLISH_PASS`。服务器和工作站 `PUBLIC_CHECK_PASS`：新IPA HEAD61709960、XML身份/缓存/MIME、三静态SHA、Android2196精确注册表、匿名401。十键最终读回和真实平台endpoint投影通过；iOS仍2194、Android2196，两端min3。
- 专项发布器5/5；前端6项RED→GREEN；完整前端519/519，退出0。源码回填仅两链接及其两项测试预期。未变业务/移动构建门禁不重复执行。无服务器镜像/配置/设置变更。
- 0700生产备份 `/opt/starchat/docs/verification/artifacts/2026-10-03/ios2194-d532f913-publish/`；私有暂存 `/opt/starchat/releases/ios2194-d532f913-20261003/`。回退先检查result三静态SHA和当次十键，匹配时原子恢复本次两文件；不要覆盖后续修改、不要删除旧包或伪造设置审计。
- 规格复核后质量/安全复核通过本轮分发范围；真机安装、旧登录/聊天/Keychain及后台通知没有用户反馈。同build重签不会使2194客户端出现更高版本更新弹窗。

[任务与计时](../workflow/tasks/2026-10-03-ios2194-resigned-distribution.md)；证据目录 `docs/verification/artifacts/2026-10-03/ios2194-d532f913-distribution/`，包含release、签名/双包比对、red/green、完整前端日志、服务器result、公网两侧报告与真实endpoint投影。首个显式clock15:46:03，终检查15:59:00；起点未知，不声称总耗时精确。临时SOCKS已关闭。
