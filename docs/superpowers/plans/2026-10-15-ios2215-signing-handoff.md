# iOS 0.4.46+2215 签名交接计划

用户批准构建 IPA 自行签名后回传分发，要求通知/后台提醒可用；明确沿用现有推送身份。此阶段构建待签名候选，不修改正式分发或 TestFlight。

1. 复用 ea9b52a4 干净工作树，移动源码与已验收2215媒体修复完全一致，复用精确共享门禁；核对当前版本、CI触发范围、APNs生产topic和身份。root拥有本次CI增量、契约测试与任务文档。
2. RED→GREEN加入现有原生通知桥接integration测试到macOS门禁；检查通知权限、token注册/pusher、前台去重、后台可见alert/sound与点击。只读检查生产配置和安全汇总日志，不泄露token/私钥，不向真实用户发送测试消息。
3. 先规格后质量审查，推送独立候选分支，仅运行 unsigned device 和 simulator 工作流。生成完整arm64 IPA，保留全部生产插件、APNs/VoIP/SQLCipher/Keychain。
4. 获取工件并校验API digest、ZIP CRC、版本、Bundle ID、完整框架与源资产，输出IPA及签名交接说明。
5. 最终签名要求沿用Team HY9Q7Q35S5、Bundle ID com.liuhetong.liuhetongMobile、生产aps-environment，保留原Keychain访问组。收到回签后核验profile与实际权益，随后真机测试后台/锁屏/冷启/通知点击/声音/Focus，才可断言真实到达；系统权限、静音、专注模式不可由应用绕过。
