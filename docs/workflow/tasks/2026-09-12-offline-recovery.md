# 2026-09-12 离线恢复修复任务

开始：2026-09-12T10:45+08:00（近似到分钟）；Astra主审，显式Terra执行。工作树.worktrees/offline12，branch codex/offline-recovery-20260912，基线1fd0354c。根工作区多份已有脏文档/lock/生成物保留。
授权：修复用户报告F1/M2/M3及离线好友资料、朋友圈、聊天媒体、我页和提示；延续Debug Mi6自测交付，不push/部署生产、不改WiFi或读取账号秘密。
计划：[实施计划](../../superpowers/plans/2026-09-12-offline-recovery.md)。原审计：[核心报告](../../verification/2026-09-12-core-feature-test.md)。
实际设备：cbd0156b online MI6，com.liuhetong.mobile version0.3.85-debug/2091，firstInstallTime2026-09-11 00:42:05，lastUpdate2026-09-12 04:10:59。2088测试报告仅作为历史复现证据。
当前：定位。Root已确认ProfileTabPage直接gateway api不读identityCache.profile；CoordinatedDirectChatGateway在findExisting前强制canonical网络查询。两名Terra并行只读sync与media根因，未改源码。
下一步：接收根因与测试方案，按文件所有权实施F1与C1，O1/O2依赖共享文件释放后串行。

## 根因确认（10:54+08，代码证据）
- F1：app_home通知bootstrapper ready后才start watchdog；watchdog hard tick对abortSync使用unawaited，立即重启；SDK abort要等_currentTransaction然后清_currentSync。SDK自身存在3s错误重试，不能将“抛错不重试”作为根因结论。需脱离通知门控装配、真实序列化abort/restart，并接网络切换与resume候选触发。
- C1：MomentMediaCache只接受/api/v1/profile/avatar/content/的稳定key，但朋友圈实际/api/v1/moments/media/content/落入含签名URL的key。修正精确路径匹配不降低origin/account要求。
- O1：CoordinatedDirectChatGateway先canonical API再本地findExisting，断网无法进入已存私聊。MatrixDirectChatBackend.requestParticipants可能联网，离线路径必须独立只读本地并严格校验现存加密双人房间。
- O2：ProfileTabPage接收identityCache但ProfileController只用widget.api.loadProfile；ProfileExperiencePage在profile null时整个菜单被spinner/retry替换。
- M3：报告的image_cache_keys不是内容哈希；service._media_cache_key实际sha256(object reference)，不可直接拿来作为Matrix内容SHA。跨模块共享需首次授权下载后本地计算字节hash，单独alias且保持账号隔离。
- 环境预检：scripts/verify.ps1 exit1；repository/deployment/template gates通过，缺.env阻断render配置，日志verify-preflight.log。未引入生产配置。


## 首片段亲审 2026-09-12T10:59:30.9507432+08:00
Root已核对app_home/watchdog实际diff与8项用例；通知门控解耦和abort串行顺序通过初审。剩余SDK迟到loopownership/connectivity/真实装配用例未完成，不宣称F1修好。前端当前源码基线npm test：166项155通过11失败(exit1)，原始frontend-baseline.log；后续比较身份。

## 审查返工 2026-09-12T11:08:04.2514022+08:00
F1第一执行者完成首片段后停止，root新建显式gpt-5.6-terra terra_sync_sdk_finish接手完整SDK/网络控制器回归；两执行者上限保持。Root实际diff发现相同Set事件重启风暴、初始soft kick阻塞force恢复、check迟到覆盖stream、plugin错误未捕获、dispose重复与offline被旧finished覆盖，已指定6项RED/GREEN。M2初稿无界每房间缓存注册表及旧flight跨页面失败已退回并改为有界完成bytes池；M3账号前缀不一致、trustedfallback注册、全局sources无界与清理竞态已退回，验收对象数与清后无回填。未打包，未称修复完成。

## 实施与亲审续记 2026-09-12T11:28:23.8370165+08:00
SDK真实Client假HTTP用例确认旧响应清新loop、迟到unknown-token副作用和retry等待残留请求；已补所有权边界。Root审查捕获并退回AppHome仅resourceCount的弱断言，改为真实watchdog动作观测。通知插件mock未被调用，不能记录为已验证通知失败；改验通知未就绪仍启动并保留此局限。最终组合日志当前仍exit1，定时器dispose路径正在修复，不以green文件名代替退出码。
媒体亲审新增发现：旧版本实际Moments缓存是URL+账号key，必须探测该真实legacy key而非仅用修正后的key伪造迁移；已实施对应迁移用例。持久clear epoch移出配额目录，未知/被LRU逐出legacy项在新provider下不得复活；avatar共享key前缀不可误拒绝。等待最终有效命令日志。当前无APK构建或安装，设备网络未改。
下一步：F1/M2/M3绿色证据复核后，Terra继续O1/O2及N1/U1；root最终门禁和保留数据安装。

## 第一批root验收 2026-09-12T11:31:20.8151332+08:00
亲审SDK完整diff、managedcapability/_withClient调用链（生命周期队列只包admission，不以softsync请求阻塞abort）、AppHome装配/退出、Moments真实legacykey迁移和clear世代/持久epoch、聊天预览生命周期。Root独立执行8个相关测试文件，66/66通过，ACTUAL_EXIT=0；root-phase1-focused.log和root-phase1-inputs.json记录证据。F1/C1/M2/M3通过代码与自动化审查，真机恢复时限/性能未实测。下一批O1/O2/N1/U1实施中。

## O1 root验收 2026-09-12T11:46:32.4927229+08:00
已亲审gateway→facade→SDKlocal room成员读取链，保留服务端协调创建逻辑原样；安全现存私聊不请求canonical/member/join。补本地数据库成员读取、迟到state不覆盖、读库异常为miss、selfjoin+peerinvite合法边界。7文件直接会话套件47通过exit0，o1-direct-chat-final-green.log；RED临时禁用local能力对照含3个预期result失败及1个heldDB等待超时，后者不作为行为断言证据。错误分类将网络/超时/同步等待/401/403区分。O1通过代码和自动化审查，真机待验收。Terra继续O2，我页菜单与缓存优先。

## O2/N1亲审续记 2026-09-12T11:58:18.4045504+08:00
O2最终55项通过、N1 36项通过，root亲读controller/repository/ProfileTabPage所有权及hub/dialog/viewer实际diff。O2发现restoreDefaultAvatar异步invalidate后仍可能覆盖新save，退回加guard/held回归；N1补真实窄屏大字与同时双弹窗防重用例。N1与watchdog绑定、HTML同步正在实施。root运行tests/mobile：67通过3失败exit1；失败测试及相关源码/注册表与1fd0354c完全相同（mobile-baseline-identities.json），包括已有GlobalSearch正则解析问题和旧26/355计数断言。未称全绿。下一步源码冻结后完整Flutter/analyze/HTML/契约。

## O2/N1产品源码审查通过 2026-09-12T12:02:24.6115219+08:00
root复核ProfileController所有await后的旧操作保护、repository联系人合并、ProfileTabPage API/session/cache归属；核对N1状态真实装配/旧owner解绑和手动retry重新检测transport、等待abort、更换loop失败显示serviceUnavailable。补充组合47项通过exit0；原始n1-o2-binding-avatar-green.log。候选0.3.86+2092已同步pubspec/AppConfig。HTML契约28组件363屏通过，frontend158通过11既有失败；root正在复核全局dialog作用域与无缓存我页文案，UI测试补真实窄屏/弹窗防重后执行最终门禁。

## 最终门禁与构建 2026-09-12T12:12:56.3853424+08:00
静态分析exit0，全Flutter2452通过/29既有钱包失败(逐项差集空)，UI契约28/363通过，frontend159通过/11既有失败，mobile67/3既有失败。root亲自浏览器发现并复核U1 re-render修复，真实DOM自测root重跑通过。Flutter候选冻结0.3.86+2092，测试后输入漂移0。源码build→Apktool固定重建→原签名正在执行（build-start.txt），未安装；下一步最终包语义/签名/设备身份核验及install-r。

## 合并基线更新 2026-09-12T12:18:31+08:00

Root已安全合并主线 `1d1db6aa` / `662c7152` 到本任务，合并提交为 `f5caf48f`。主线新增好友 presence 自取及资料页 Android/iOS 下载链接；本任务继续保留 O2 缓存优先和资料缺失时菜单可用行为。设备上的 2091 与已验证但未安装的 2092 候选均不复用，下一候选调整为 `0.3.86+2093`；不构建、不安装。下一步：定向资料/联系人/版本回归及静态分析，root 后续自行执行完整门禁与 2093 构建。

## 安装前并行漂移拦截 2026-09-12T12:16:40.0049362+08:00
2092候选重建成功exit0，SHA0aedb3788140632e66ba548ce780043dfde63a5d42a39113a63e1af7eb53f9f8；manifest语义/27250类/339native+asset内容均一致，原签名匹配。但最后device读取发现已由其他工作更新为0.3.85-debug/2092（lastUpdate10:58:30），main也从1fd0354c前进到1d1db6aa，包含662c7152好友在线自取与安卓/iOS复制下载链接。未安装旧候选、未覆盖新功能。root亲读12文件diff，merge本地main为f5caf48f（profile_page自动合并），根工作区未改。执行者升2093并回归合并影响，随后重跑最终门禁、重建新候选。原device2092 APK已拉回验证固定证书相同。
