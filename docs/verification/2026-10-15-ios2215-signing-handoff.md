# iOS 0.4.46+2215 签名交接检查

## 范围与身份

用户授权生成待签名 IPA，回签后再分发，并明确沿用现有推送身份。本次不发布官网或应用更新设置。候选源 a24e40cb9818b7f94ca7f10380826e67cafd1b46，CI 38735034870/attempt 1；移动源码与已验证媒体修复基线5e1ad763一致。本次代码变化仅为CI加入已有原生通知桥接测试及相应契约。

## 已有证据

- CI契约RED为1失败/1通过，新增目标后相关包装/原生门禁契约59通过。共享Flutter5965通过/9跳过、analyze0及Python边界401/1按输入相同复用，记录见artifacts目录shared-gate-reuse.json。没有宣称全仓verify通过：已有环境缺.env限制保持。
- 生产Sygnal镜像sha256:90fa02ff684b44aaaa08971845c2ed21d1d838eb4fb38c9e649d69a5be360dd0运行。生产app_id=com.liuhetong.mobile.ios、topic=com.liuhetong.liuhetongMobile、Team=HY9Q7Q35S5；keyfile存在，push_type=alert，convert_device_token_to_hex=false。未导出密钥或设备token。VoIP网关healthy。
- 同一生产镜像的隔离契约11通过，网络禁用、传输mock，验证可见提醒/声音/DND/重试/隐私载荷，不是APNs端到端投递。
- Synapse只读聚合9条iOS pusher，9条均event_id_only、正确HTTPS网关、可见默认alert及default声音；policy_v1=0为既有客户端状态，2215将注册新策略。
- 24小时685行Sygnal日志聚合未发现可用真实APNs发送/接受样本；零错误计数不能推导100%到达。
- 客户端使用原生APNs十六进制token；前台由本地通知处理并抑制远程重复；后台使用系统可见alert；点击房间路由/角标/清理桥接有专项覆盖。提醒为通用文案，保留E2EE边界。

## 签名与真机待验

待签名包的Runner.entitlements是源配置，不是最终签名权益。签名方需保留指定Bundle/生产推送身份，回签后核对embedded profile、已签权益、嵌套框架、App ID Prefix和Keychain。旧2213指定回签包的application-identifier不同，不能直接承诺覆盖安装和已有密钥连续性。

待执行：回签包脚本核验与内容比较、旧数据iPhone不卸载覆盖、前台/后台/锁屏/退出/离线恢复实际推送、声音/角标/点击去重和冷启动路由、媒体发送。记录每条发送/接受/展示时间与结果。通知权限、静音和专注模式按iOS用户设置生效。

Apple参考：[APNs注册](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)、[APNs请求](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)、[aps-environment权益](https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment)。

## 构建与产物

CI启动2026-10-15 20:29:33+08；device于20:38:05+08成功，simulator于20:44:52+08成功，CI墙钟15分19秒。原生目标1+13+6+1=21项通过，均attempt1/exit0、无stall或timeout；device权限hook2项通过。模拟器为iPhone15/iOS26，只在诊断宿主排除无arm64模拟器slice的mobile_scanner，完整真机IPA保留生产插件。IPA34966220字节，SHA256=`137e447798deca216d555b5daa82d6da631a7df925e9738b961fbccc4b2713d7`。本地verify_download.py退出0：CI/source/manifest/ZIP CRC/arm64设备Mach-O/SQLCipher导出/权限/源资产匹配。Downloads及主目录delivery副本SHA一致；交接路径见[IPA](artifacts/2026-10-15/ios2215-signing/delivery/ChatFlow-0.4.46-build2215-unsigned.ipa)和[签名要求](artifacts/2026-10-15/ios2215-signing/delivery/SIGNING-INSTRUCTIONS.txt)。本机下载约20:38:49至20:50:44+08，准确网络结束时刻未单独记录。阶段前精确人工工时未完整记录，不推算。
构建维护观察：7个插件尚未支持Swift Package Manager，当前由CocoaPods完成构建；Flutter提示未来可能改为错误。本次Xcode构建成功，列为后续工具链升级兼容性事项，未隐藏告警。

最终独立规格→质量审查通过：实际IPA大小/SHA/CRC/版本/Bundle/未签名状态与来源及测试证据匹配。允许交付用户签名；未关闭回签和真机待验项。
