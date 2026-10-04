# 全局搜索与验证码跟进

## 恢复入口

- 用户2026-10-05要求S1全局搜索跳目标气泡、O1手机OTP15分钟、L1查短信阻塞、U1未同意协议toast、C1双渠道60秒离页冷却保留。
- 计划：[本轮计划](../../superpowers/plans/2026-10-05-global-search-otp.md)。源基线e3f10d6f；隔离worktree C:/Users/Administrator/.codex/worktrees/search-camera-history-20261003/StarChat；branch codex/global-search-otp-20261005。模拟器上轮实际2201；新候选尚未核号/构建。
- root文档/ADR/版本构建/只读生产；global_search_anchor_2202仅search模块及新测试；otp_client_cooldown仅auth模块及新测试。初始调查，不允许同文件/Flutter并发。
- 2026-10-05T03:50:39.6455167+08:00已读现行工作流/spec/ADR。代码证据：手机本地OTP300秒，阿里默认5min/校验上限10min；不同证明期限不可批量替换。手机登录controller冷却随页面销毁，其他Timer按tick而非deadline。
- 下一步：分别页面RED及短信期限ADR/domain review，生产聚合调查。不复用2201测试作为新变更通过证据。

## 验收台账

| ID | 预期 | 当前证据 | 状态 |
| --- | --- | --- | --- |
| S1 | 全局关键词命中定位正确事件/来源气泡及上下文 | 真实页面49PASS，全量5455PASS，模拟器2202已安装 | 用户确认三项均正常 |
| O1 | 所有手机OTP本地/供应商一致15分钟，安全规则保持 | 163专项/映射PASS，生产两角色900/15回读PASS | 已部署，新发验证码15分钟 |
| L1 | 明确短信请求/投递/锁是否阻塞 | 两次48h日志/Outbox/PG聚合 | 未见当前阻塞，具体运营商投递无法关联 |
| U1 | 无协议勾选toast且无请求 | 180 authPASS及全量门禁 | 用户确认三项均正常 |
| C1 | 手机/邮件退出重进冷却继续 | 重建页面/迟到响应/隔离/到期测试 | 用户确认三项均正常 |

## 阶段与边界

生产只读观察03:53前后：business-api image2fd052541347、worker3efd5924f343健康；隔离recovery worker显示unhealthy需另行判断，不能冒称生产短信worker阻塞。无发送/账号修改/秘密读取或生产写入。整库verify环境仍需本轮预检。上轮1372无关WIP保全快照可作为本轮起点再次核对。

2026-10-05T03:55:15+08 L1只读聚合：48h API222514/gateway154101/worker6020日志行未命中列举SMS错误码；不代表未记录的运营商延迟不存在。OTP路由202/200可见，email-rebind429一例符合限流；PG当前无Lock waiters/阻塞PID，identity.email6事件全PUBLISHED/max2.548745s，identity.password_phone无48h事件，OTP无待发送活跃挑战。API及worker实际供应商配置5min；真实挑战期限300秒。没有日志request_time指标，不能推断API完整延迟分位数。原始日志只在远端RAM，落地仅计数/状态/期限。

03:56运行来源：API2fd052541347…/opt/business-api/app，worker3efd5924f343…site-packages/app；config/phone内容两角色不同，禁止全repo覆盖运行worker。短信期限rootdomain设计接受，邮箱注册10min/其他EMAIL5min及非OTP证明保持；候选必须应用实际base最小变换、保留所有非短信差异。SDD新serveragent因threadlimit无法创建，复用已完成prepare_recovery_deployment新边界，不重新执行旧任务。

## 05:04 实施与生产回读

上方台账保留初始状态；本段为更新事实。候选源 b54cf6fab5030f98c5834adff485966721b23de5，0.4.33+2202。

- S1：修复 RoomPage 首次缓存投影无通知时未应用 route anchor；真实 GlobalSearchPage → RoomPage 测试包括立即/延迟历史上下文、已有路由重入和正确高亮气泡。49 项通过，root 独立规范/质量审查接受。
- U1/C1：共享 gateway 生命周期、按渠道/目标/用途/认证作用域隔离的绝对截止时间；旧页面迟到响应不能重置新目标。未同意协议在发送/提交前 toast，注册页面恢复和切换渠道同步冷却。180 项通过，局部分析 0 issues，独立规范/质量审查接受。仅页面退出重进保持；进程重启后服务端限流仍权威。
- O1：7 类手机 OTP 900 秒，本地与供应商 ValidTime 900 / 模板 15 分钟一致；邮件和证明期限、尝试数、限流及绑定校验保持。121 专项通过；更广测试 630 通过/40 PostgreSQL 环境跳过/3 个旧短信期限断言失败，修正期限夹具后受影响完整文件及专项共 163 通过。并未声称跳过的 PostgreSQL 测试通过。
- 生产 05:02:02–05:02:45：按实际 API/worker 不同基镜像仅覆盖 3 个 TTL 文件；独立部署脚本复审（含未知切换禁止回滚、持久 pending、重试拒绝）接受。生产 receipt PASS：API 03c5647d…、worker 7146c723…，实际导入文件 hash 一致、两角色 healthy、手机 900 秒、供应商 15 分钟；7 个受保护容器身份未变。已有旧挑战保持原期限；新发送使用 15 分钟。未发送真实短信。
- L1：切换后再次只读聚合仍无当前 PG 锁等待和 OTP Outbox 积压。用户补充登录/注册、云南 IP，缺具体时间；无法关联具体短信投递或证明运营商延迟已消失。原始日志仅 RAM，证据仅聚合。
- Flutter 全库静态分析 0 issues。首次全测因未加已知 libolm DLL 路径有 4 个 setup 失败；已加冻结 Olm/SQLCipher 路径，保持原失败记录，第二次全测运行中。
- iOS CI 37233001043，源 b54cf6fa：完整生产插件编译通过，iOS 18 重启恢复通过，iOS 26 仍运行；不作真机或永不 L04/L07 保证。
- Android 构建冻结 1875 输入，manifest 43c42d48…；稳定签名预检通过，模拟器仍 2201，尚未构建/安装 2202。主分支尚未集成。

下一可执行步骤：全库 Flutter 第二次结果 → 按常规 DEX/资源/manifest 重建、校准签名验证并保留数据安装 2202 → 完成 iOS 26 与最终证据审查 → 保全 1372 无关 WIP 快进主分支及推送。整库 verify.ps1 缺本地 .env/local.env 的必要配置，未导入生产秘密来运行；平台专用检查仍继续。

## 05:10 Android 与全库门禁

04:57:08–05:05:59 第二次 Flutter 全测5455PASS/9skip/0FAIL，source b54cf6fa，已知冻结 DLL 路径入PATH；31.7秒静态分析0问题。首次setup环境失败及旧服务断言失败记录保留，不用后续PASS覆盖历史。

05:06:25–05:08:50 Android source→Apktool2.12.1→zipalign16→稳定签名→独立decode语义/原生锁验证全通过。0.4.33+2202 standard-x64-debug；1875输入manifest43c42d48…，publock ac0966cb…前后一致。成品135737571bytes，SHA256 90564536c7d4c4b921a31953f320ea28ca06315e0dbb667bd7186349c048b1b9，固定单签名75b31c66…/v2v3。

05:09:14–05:09:59 emulator-5556 install -r，仅更新debug包；2201→2202，UID10090及首次安装2026-09-26 04:06:20保留。读回base.apk同成品SHA，launch ok，PID7497短时持续；不等于真实账号消息跳转人工验证。已向用户请求三项页面复测，未有回复不阻塞其他交付。

生产公网正确路由/api/v1/health/ready HTTPS证书验证启用，05:07:51返回200/database ready；此前错误探测/api/health/ready和/health/ready返回404，仅是探测路径错误，未修改网关。

下一步：iOS26最终CI、最终平台证据复审、文档/证据归档及保全WIP主分支推送。正式手机安装包网站/App Store/TestFlight未发布。

05:12读取CI最终状态：37233001043 exact b54cf6fa run SUCCESS，三job均SUCCESS；iOS18/26 host、native首次seed及新进程保留Keychain/SQLCipher/历史、完整生产插件compile均成功。已复用同输入最终证据，无重复CI/重编译。下一步仅最终复审、归档和主分支保全推送；用户真实页面反馈单列，非合成测试结果。

用户随后回复已安装2202的三项页面复测：“三项均正常”，覆盖全局搜索对应气泡/滑动上下文、未同意协议toast、手机/邮箱离页重入保留倒计时。S1/U1/C1人工反馈已关闭；不扩展为短信运营商投递、iOS真机或进程重启冷却的验收。

05:15 main快进40b261ff，1372无关WIP hash保全、candidate交集0/index空、原current-state正文保留，mobile tree5cd2a854…与全测试/构建b54完全等价。仅文档收尾后推送并读回远端确切HEAD，收据main-integration.json/main-push.json；不重复同源5455/163/180测试或平台构建。任务范围已完成，未发现可定位的短信阻塞；云南具体投递情况保留证据限制。
