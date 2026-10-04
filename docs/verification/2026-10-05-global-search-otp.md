# 全局搜索与验证码修复交付

源候选 b54cf6fab5030f98c5834adff485966721b23de5；模拟器已实际安装 **0.4.33+2202**。手机验证码15分钟已实际部署API与worker。任务及授权：[任务](../workflow/tasks/2026-10-05-global-search-otp.md)、[计划](../superpowers/plans/2026-10-05-global-search-otp.md)、[认证期限ADR](../adr/2026-10-05-phone-otp-fifteen-minutes.md)。

| 用户需求 | 改动与实际证据 |
| --- | --- |
| 全局搜索点击命中跳对应气泡 | RoomPage第一次缓存投影ready后启动既有一次性anchor。实际GlobalSearchPage导航→RoomPage目标bubble/highlight、延迟SDK上下文、重入及来源边界49PASS。 |
| 所有手机验证码15分钟 | 7类SMS本地900秒，阿里云ValidTime900/template15。邮箱及非OTP证明期限保持；尝试数、用途/账号/会话绑定、单次消费和限流保持。生产两角色真实配置与模块hash回读一致且healthy。 |
| 未勾协议提醒 | 手机登录/注册发送及提交可点击，协议检查优先toast，未同意不发请求。 |
| 双渠道60秒离页冷却 | 同gateway共享、渠道/目标/用途/身份作用域隔离的绝对截止时间；离页重进、后台、迟到429及目标切换测试。进程重启后UI内存计时不保存，服务端限流保持权威。 |

Flutter完整5455PASS/9skip/0FAIL、analyze0；auth180PASS；server最终163专项/映射PASS。更广服务测试630PASS/40PostgreSQL环境skip/3个旧短信期限夹具失败，改为900秒边界后163映射关闭全部3项。初次移动全测4个setup因Olm DLL PATH遗漏失败，冻结运行库入PATH后同源完整复测通过。历史失败日志均保留。

Android按source build、常规DEX/resource/manifest重建、16KiB对齐、固定单签名v2/v3、独立解码语义/锁边界验收。1875输入manifest43c42d48…，成品SHA256 **90564536c7d4c4b921a31953f320ea28ca06315e0dbb667bd7186349c048b1b9**。05:09保留数据覆盖安装，UID10090和首次安装时间不变，读取设备base.apk哈希完全一致，启动正常。

[最终模拟器APK](artifacts/2026-10-05/global-search-otp/android-debug/run-20261005-050625/final.apk)、[构建收据](artifacts/2026-10-05/global-search-otp/android-debug/run-20261005-050625/artifact.json)、[安装收据](artifacts/2026-10-05/global-search-otp/android-debug/run-20261005-050625/emulator-install-2202.json)。用户随后明确反馈“三项均正常”：全局搜索定位及上下文、协议toast、手机/邮箱离页重进冷却均通过模拟器人工复测。合成页面测试、启动观察和用户反馈分别记录。

生产05:02部署仅3个TTL模块的可逆补丁，保留API/worker实际不同基镜像的所有非TTL内容。新镜像API03c5647d…/worker7146c723…，既有双角色续期协议17项、nativeCompose实际环境/挂载/网络一致、手机900秒/供应商15分钟均通过，7个其他容器身份不变。[部署收据](artifacts/2026-10-05/global-search-otp/production-deployment-receipt.json)。HTTPS正确公网路由健康200，数据库ready。原有验证码仍用原期限，新发验证码15分钟；未发送真实测试短信。

两次只读48h日志/Outbox/PG聚合未见当前数据库锁等待和OTP任务积压。用户提供登录/注册、云南IP，缺具体时间，无法关联具体投递；没有证据保证运营商延迟消失。原始日志仅RAM，存档只含聚合。[切换后观察](artifacts/2026-10-05/global-search-otp/production-otp-observation-after.json)。

iOS CI [37233001043](https://github.com/SuperJJ2333/StarChat/actions/runs/37233001043)绑定b54cf6fa，05:11:49完整run成功：生产完整插件编译、iOS18与26 host测试、native媒体/加密历史seed、新进程保留Keychain/SQLCipher及历史均通过。未正式发布移动版本/IPA，未作真机或永不L04/L07承诺。整库verify.ps1必要本地.env/local.env配置缺失，未导入生产秘密执行；专用平台、认证、E2EE检查按实际证据完成。

05:15主分支已快进集成40b261ff，1372无关WIP内容hash逐一保持、候选重叠为0、index为空，原current-state正文逐字节保留。[集成收据](artifacts/2026-10-05/global-search-otp/main-integration.json)记录源及移动tree等价；后续仅交付文档收尾，不重复同源平台门禁。最终推送记录见[主分支回读](artifacts/2026-10-05/global-search-otp/main-push.json)。平台最终复审见[候选审查](artifacts/2026-10-05/global-search-otp/final-candidate-review.md)，各组件按规范先于质量审查接受，部署helper异常恢复保护独立复审接受。
