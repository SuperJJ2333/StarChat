# iOS 2144 官网与安装入口修正
用户明确授权三项修正；不改变版本、最低版本、更新说明或Android。
工作树 codex/ios-distribution-2144，基线83c2f196；拥有 frontend/download.html、frontend/src/admin-home.js、对应测试及本任务文档。
计划：docs/superpowers/plans/2026-09-20-ios-distribution-2144.md。
## 验收
- 官网及下载页：0.3.102（2144）、44.2MB，已上线。
- 电脑IPA链接：现有 /downloads/ChatFlow-0.3.102-build2144-ios.ipa，线上SHA与用户附件相符。
- 弹窗：仅 app_ios_download_url 改为 https://www.liuhetong888.com/download?platform=ios&install=1；SettingService审计1条；其余两端设置逐键相等。
- 测试：先2失败（旧版文案），修正后定向6通过；frontend全量218通过，exit0。未改程序逻辑，只静态发布元数据与既有配置；按mobile-delivery-workflow变更影响规则，不重复后端/移动构建门禁。
- 公网：页面内容及SHA一致、IPA Range206、manifest application/xml及no-store、未登录更新接口401。
- 规格审查：全部三项符合，未改Android；质量审查：HTTPS/固定IPA/审计/0700备份/漂移门禁/回退路径保留。
## 证据和回退
证据 docs/verification/artifacts/2026-09-20/ios-distribution-2144/。备份服务器同路径加 /opt/starchat/ 前缀，rollback.md描述恢复。API镜像fb41d7fa未更改；IPA与manifest未更改。
发布约2026-09-20 19:53+08；准备约19:49+08，精确主动时间未计量。前端测试1.75秒。
下一步：用户在iPhone重新检查更新，Safari确认系统安装；真机企业签名信任/安装尚待反馈，不能以服务器验证替代。

## 20:04+08 后续安装失败排查
用户确认iPhone8/iOS16.7.16，系统协议提示后无安装确认。生产appstored日志显示清单200后没有IPA安装请求。发现线上manifest缺少关闭plist标签，plistlib失败 no element found line31；补齐后服务器和工作站HTTPS实际内容均解析通过，SHA a7b89bf847cdfe413c9ad2cb50eab3ffa897d5c363e472aa92cab5c2bfc4de6f。旧清单备份到发布目录manifest-malformed-before.plist。本次未改变任何更新设置。
独立阻碍：用户提供IPA及生产IPA SHA48721e9c一致；Info.plist bundle ID=com.liuhetong.liuhetongMobile，但主程序签名entitlements和embedded.mobileprovision的application-identifier均为ZXB3TS7QD4.cn.edu.buaa.wxwork.notifyext，不匹配。本次确认enterprise标记并不足以证明签名有效；不得声称安装验收通过。需合法匹配该bundle ID的签名配置重新签名，不能更改bundle ID来绕过并破坏覆盖升级。下一步用户重试以确认清单阶段恢复，签名包待重新提供及验签。
