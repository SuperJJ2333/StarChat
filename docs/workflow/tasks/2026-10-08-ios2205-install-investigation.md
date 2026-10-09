# iOS2205 点击安装确认后无后续动作调查

用户反馈“想要安装畅聊正式版”确认后无反应。排查遵循systematic-debugging：先验证入口→HTTPS清单→IPA传输→签名身份/实际CMS，并等待设备情况，不无依据改网页或签名。

- 精确候选SHA a122af8389bcae5e25506b71e93181d6164e9007e8a859ed5f83a129c769a653，0.4.36+2205/47743050字节/iOS16.0+。
- 19:30+08复查HTTPS清单200/XML/no-store，IPA200/正确长度；清单BundleID/version/URL匹配Info.plist，按钮使用itms-services链接。出现系统安装确认说明用户已进入系统OTA流程，不属按钮完全未触发。
- 19:31:22+08前30min网关聚合：iPhone/iPad/itunesstored/appstored UA组清单9次200，当前IPA6次200；没有IP或完整日志落盘。不能把UA组聚合绑定用户单次，也不能把200当完整传输/安装成功。
- 签名身份异常：包内BundleID com.liuhetong.liuhetongMobile，但profile及Runner已签AppID 7XL5R8V6RC.com.qiming.newhqzl299；Team7XL5R8V6RC/Keychain7XL5R8V6RC.*、企业profile有效至2027-05-18/生产APNs。标准最终签名检查实际exit1：profile or signed application-identifier does not match bundle identity。
- 48个实际Mach-O CMS内容签名检查48PASS/0failed；仅证实签名数学关系，不证明Apple证书链、撤销状态、页内容/资源seal或iPhone升级可行。
- 当前能确认的缺陷是回签身份不匹配；可导致安装/覆盖升级失败，用户这一次的直接根因尚需设备错误/旧包身份确认。此前发布渠道Team A9HAF6NT6S为历史证据，不当真机当前身份基线。
- 没有签名证书私钥/正确profile，不能通过网页改BundleID或改签名IPA伪装修复；需签名方对com.liuhetong.liuhetongMobile生成匹配profile和AppID，并兼顾旧签名Keychain/覆盖安装兼容。
- 证据目录：docs/verification/artifacts/2026-10-08/ios2205-install-investigation，signed-identity、request-aggregate、strict-signing-check.log、code-cms.json。未改生产、未下架/重发或关闭弹窗；用户未授权这些额外动作。
- 下一步：用户说明是否安装旧版、iOS版本和灰色图标；必要时取iPhone安装错误日志。不要要求卸载持有唯一旧聊天数据的App。

Apple依据：https://developer.apple.com/library/archive/technotes/tn2319/ ，区分AppID配置和覆盖旧包identity失败；https://support.apple.com/en-gb/guide/deployment/depce7cefc4d/1/web ，区分HTTPS分发与设备企业信任。本次未宣称已验证设备信任。
