# iOS 2189 企业分发核验

**已发布** iOS 企业版 `0.4.20/2189`。回传 IPA 本地、服务器公开文件 SHA256 均为 `6afd6827b5d8bbef84b7384a59a97aa52e03fde5a4825d9ec684972eeb51b51f`，长度均为 61,871,956 字节；独立公网 HEAD 200。用户明确批准沿用既有企业签名渠道。20/20 Mach-O 签名检查、普通文件比对、历史 dylib 比对完成；既有 application-identifier 与 Bundle ID 差异保留为真机验收风险。

发布器于 2026-09-28 13:18:26+08 返回 `PUBLISH_PASS`，后续 `METADATA_CHECK_PASS`；清单、下载页和首页指向该不可变 IPA。更新设置经 SettingService 读回 iOS `0.4.20/2189`；同次审计三条 SUCCESS，其中 URL 为同值更新。Android `0.4.19/2188`、最低版本、更新说明、旧 iOS 包、容器及 schema0090 保持。匿名更新接口返回 401，**没有已鉴权 HTTP 更新投影或真机更新弹窗证据**，仅能确认服务端配置及发布路径。

参考[任务台账](../workflow/tasks/2026-09-28-ios-enterprise-distribution.md)、[签名核验](artifacts/2026-09-28/ios-enterprise-distribution/ipa-verification/report.md)、[独立生产后验](artifacts/2026-09-28/ios-enterprise-distribution/preflight/postpublish/report.md)、[独立公网后验](artifacts/2026-09-28/ios-enterprise-distribution/review/postpublish/report.md)、[服务器完整 SHA 收据](artifacts/2026-09-28/ios-enterprise-distribution/server-ipa-sha256.txt)。本轮操作证据集中在 `artifacts/2026-09-28/ios-enterprise-distribution/`。API261f/0091仍等待独立授权；跨设备新视频封面在该服务上线前不宣称生效。真机安装、APNs、Keychain 连续性待设备验收。
