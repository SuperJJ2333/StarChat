# 2026-09-12 断网恢复与离线页面修复验证

状态：修复及当前环境验证完成；0.3.86-debug/2093 已保留数据覆盖安装 Mi 6。功能与真实切网性能由用户验收；全量门禁存在已记录的无关基线失败。

源码基线：main `1fd0354c`，隔离工作树 `.worktrees/offline12`，分支 `codex/offline-recovery-20260912`。主代理制定计划并审查实际 diff；执行代理创建时显式指定 `gpt-5.6-terra`。根工作区既有未提交修改保留。

## 复现与根因

|编号|复现|源码根因与修复方向|
|---|---|---|
|F1|断网10秒后恢复或WiFi切蜂窝，界面可看旧消息却不再接收|看门狗启动受通知初始化门控；硬重启未等待abort；SDK迟到Future可以清除新loop。脱离通知门控，接入网络变化/前台恢复，串行abort并以generation保护loop所有权|
|C1|重进朋友圈，签名URL轮换后旧缩略图未命中|稳定key只接受头像路径，遗漏真实moments/media/content路径；修正可信origin+account+精确路径匹配|
|M2|退出再进入聊天室，媒体再次占位刷新|页面dispose清除预览内存，新页面重新读盘解密。保留有界的完成bytes池，页面flight仍各自管理|
|M3|相同内容出现在聊天和朋友圈，两套磁盘缓存|Moments DTO image_cache_key是对象引用hash，不是字节hash。授权下载后计算真实SHA并引用同账号共享对象，旧缓存需可离线迁移，清缓存必须防止迟到写入及重启复活|
|O1|断网时好友资料点击发消息进不去已有私聊|gateway先调用canonical业务API，local findExisting还可能requestParticipants联网。增加独立安全本地查找，未命中仍按原服务端协调建聊|
|O2|断网打开我页，资料及功能入口不可用|ProfileTabPage未接身份快照，profile==null时整页菜单被重试/加载替换。快照先显示、网络后台刷新，菜单始终可用|
|N1|网络失败文案笼统、重连无感知|统一网络链路/服务同步状态与主动操作弹窗，保留已加载内容；不得用缓存赋予业务写权限|

## 分批自动化与环境结果

- SDK旧代码对照：迟到成功、迟到错误、dispose后迟到响应3个断言失败（实际exit1）；补充retry等待ownership失败对照。当前对应修复通过的原始日志位于本任务 artifacts，最终总数在冻结后记录。
- O1 本地私聊恢复：临时禁用新增 cache lookup 的对照命令实际 exit1，已连接双人、已邀请对端及数据库冷启动快照均按预期无法返回房间。该首个对照中的 held-DB 用例曾因等待未加界限触发测试框架 30 秒超时；随后给测试等待加 1 秒边界，不将该 fixture 超时作为行为证据。恢复实现后的完整 direct-chat 批通过 47 项、实际 exit0，原始日志为 `artifacts/2026-09-12/offline-recovery/o1-direct-chat-final-green.log`。测试在初始本地查找实现片段之后补充，对照通过临时仅禁用该查找重建；本次记录如实保留。
- O2 资料缓存与页面：无缓存时“我”页缺少设置/朋友圈的基线定向用例实际 exit1；缓存资料首帧、刷新失败保留旧资料、保存压制迟到加载、销毁保护、仓储重建与 hydration/save 竞争均已覆盖。首次组合运行被外部终止（actual exit -1），第二次因并行 N1 的非 const 组件编译失败（actual exit1，非 O2 源码）；修复后最终 profile/avatar/repository/AppHome 回归 55 项通过、actual exit0，原始日志为 `artifacts/2026-09-12/offline-recovery/o2-profile-regression-green.log`。
- 前端未改基线：166项，155通过/11失败，exit1，`frontend-baseline.log`。最终需逐项对比，不能声称全绿。
- `scripts/verify.ps1`预检：仓库/部署/模板门禁通过，缺本地.env阻止配置渲染，exit1；未复制生产秘密。
- 真实手机只读基线：Mi6 cbd0156b，com.liuhetong.mobile，0.3.85-debug/2091；首装时间2026-09-11 00:42:05。后续只install-r保留数据，不操作网络配置或清缓存。

## 用户真机验收用例（尚未执行）

1. 在有新消息的测试好友/群中，记录一次短断网后恢复及WiFi/蜂窝切换。网络可达后目标5秒内开始新的sync请求；新消息正常补拉，切会话/回前台无需杀进程。通知权限关闭时同样恢复。服务异常时显示连接状态，不能虚假显示已恢复。
2. 联网浏览聊天图片/GIF/视频及朋友圈缩略图后退出重进，已缓存媒体应立即显示，不反复占位/闪烁；再离线重进读取成功缓存，未下载资源显示明确离线占位。升级前已缓存朋友圈图片也应可用。
3. 离线从通讯录及朋友圈不同入口进入同一好友，点击发消息打开已有加密私聊，本地历史正常；从未建立的房间应提示需联网，不能重复创建。恢复网络后发送和原协调唯一性正常。
4. 离线冷启动/切到我页，已缓存头像/昵称正常；设置、朋友圈入口可点击。无本人资料缓存时只身份区显示重试，其余菜单保留；刷新失败不抹掉旧资料。
5. 显示离线、正在连接、服务暂不可用状态，恢复后状态消失；自动后台刷新不连续弹窗；主动操作失败弹窗取消可关、重试不叠加。同一账号不同页面文案一致，换号不残留旧状态。
6. 同一GIF连续发送10次、同一视频双方多次转发、同内容不同名、异内容同名、清缓存后再发送；按实际网络请求/对象文件数/内存与磁盘增长核验。同账号聊天+朋友圈完成授权下载后相同字节对象只存一份；不同账号仍隔离。

限度：本次Windows自动化不能证明Mi6触感、Android9真实切网时间或release帧率；不在生产造100群/压力流量。M2 release性能需profile/release构建+DevTools的真实帧证据；100群×1000条、弱网多端和长时压力沿用核心报告附录测试方案。

## 实际改动与审查结论

- F1：`matrix_sync_recovery_controller.dart` 订阅网络变化、过滤同值事件、处理前台与手动恢复；`matrix_sync_watchdog.dart` 等待 abort 再替换 loop、单飞重试、明确离线/连接中/已同步/服务不可用；`app_home.dart` 不再把看门狗启动绑在通知就绪之后。vendored Matrix `client.dart` 以 generation + Future identity 隔离迟到成功、错误、重试及事务边界。SDK 原有 3 秒错误重试仍保留，未改加密算法、推送授权或服务端。
- C1/M2：`moment_media_cache.dart` 对可信源真实 Moments 路径采用稳定身份；`room_image_preview_cache.dart` 与 `room_page.dart` 在既有 32MiB 上限内复用已完成预览 bytes，保留页面级取消能力。不是扩大到无界每房间缓存。
- M3：`media_cache.dart` 与 Moments 授权加载后按真实内容 SHA 写同账号共享对象；保留引用和账号边界。旧 URL/账号缓存支持迁移，clear epoch 持久化在配额目录外；已清理后的迟到结果不回填。
- O1：`coordinated_direct_chat.dart` → `matrix_e2ee_client.dart` → `matrix_direct_chat_adapter.dart` 增加独立 local-only 路径，检查已加入、加密、对端/本人成员及完整性，必要时仅读本地成员数据库；未命中继续服务端 canonical/幂等协调，不在离线创建房间。`direct_chat_failure.dart` 区分断网、超时、认证、权限和等待同步。
- O2：`profile_controller.dart` → `ProfileTabPage` → `profile_repository.dart` 先用账号快照，保存后持久化、迟到读取不覆盖新值；保留联系人，controller 更换受 API/session/account 约束。`profile_page.dart` 缺资料只影响身份区，保留功能入口。
- N1：`app_connection_status.dart`、`network_status_capsule.dart`、`wechat_scaffold.dart` 提供共享状态提示；聊天图片/视频、朋友圈大图及图库异常分支补齐提示。主动媒体重试弹窗按真实错误分类并在 root navigator 防重，取消不发重试，401/403 等不冒充断网。自动刷新不会主动连弹模态。

代码审查先核规格（本地先读、现存私聊不联网、真实 sync 完成才恢复状态），再核并发/安全（旧账号隔离、clear 回填、权限错误分类、E2EE/账本/Getui 未变）。发现并修复了 SDK 迟到所有权、清缓存复活、旧资料覆盖新保存、旧 owner 解绑新会话等问题。未将子代理总结直接当成验收。

## 限制与已知差异

- 恢复请求 ≤5 秒是本次用户真机验收目标，Windows 单元测试不能证明 Android9 实际恢复 SLA；abort 如等待真实数据库事务，仍坚持等清理结束，15秒仅诊断而不抢跑新 loop。
- 同账号聊天与朋友圈必须分别获得授权后才能共享相同 bytes 对象；跨账号不共享，跨设备秒传未增加。未知旧签名 URL 已变且元数据不可恢复时，无法离线推导历史文件身份；可识别的现存 legacy 项已覆盖升级迁移。
- 群规模、长期稳定性、release 帧率/PSS、iOS 原生网络插件及真实多端切网未验证，不把 debug 自动化作为量化性能承诺。不改变手机网络设置，不在生产造压力数据。
- HTML demo 使用本地样例，能检查渲染和交互状态，不能证明服务端或真机联网。Figma 已退役：本次变更仅更新 HTML demo（`frontend/index.html`）。

## 首次候选门禁（源码 0.3.86+2092，安装前被新候选替代）

|命令/证据|结果|
|---|---|
|`flutter analyze --no-pub` / `flutter-analyze-final.log`|exit0，无问题；初次9项与中途2项新增lint均已修复后重跑|
|`flutter test --no-pub --reporter expanded` / `flutter-full-final.log`|2452通过、29失败，exit1；与既有钱包29项逐项一致，无其他失败，`flutter-failure-comparison.json`差集为空。钱包源码/测试与2088基线commit6be55572无差异；本次共享scaffold改动由完整回归覆盖|
|`py -3.12 -m pytest tests/mobile -q` / `mobile-boundaries-final.log`|67通过、3既有失败，exit1；GlobalSearch调用正则与过期组件/页面计数断言。修复前相关输入SHA已记录，最终仍是这3项|
|`py -3.12 scripts/verify_ui_contract.py` / `ui-contract-final.log`|exit0，28组件/363屏通过|
|`npm test` / `frontend-final.log`|159通过、11失败，exit1；相对初始155通过/11失败增加4项通过，失败身份差集为空，见`frontend-failure-comparison.json`|
|`node scripts/offline-recovery-browser-test.mjs` / `root-browser-final.log`|root独立执行exit0，真实DOM点击资料重试/朋友圈弹窗重试，文字更新为连接中且按钮禁用、弹窗关闭|
|`pwsh -NoProfile -File scripts/verify.ps1` / `verify-preflight.log`|exit1，仓库/部署/模板门禁通过；缺本地.env阻断后续配置/服务环境门禁。本批无服务端/数据库变更，不导入生产秘密强行执行|

完整 Flutter 门禁与候选源码相关文件SHA记录在`final-gate-inputs.json`，结束时比对漂移0。UI真实窄屏320×640、1.5倍字体及同root导航双弹窗测试5项通过。不是仅凭测试文件名或“green”日志名判断通过。

HTML路径：`frontend/index.html?screen=messages-network-offline`、`messages-network-connecting`、`messages-network-service-unavailable`、`moments-timeline-cached-offline`、`moments-timeline-no-cache-offline`、`moments-timeline-explicit-retry`、`profile-home-cached-offline`、`profile-home-no-cache-offline`（后续id均作为screen参数）。注册表`packages/ui-contracts/changliao-component-registry.json`保持原onRetry/reconnecting并增加label/disabled、连接中与服务不可用状态。

root实际浏览器检查390px页面与取消→重新打开→重试操作。首次发现只setAttribute未触发StrictElement渲染，已经退回修复并用真实浏览器RED/GREEN证明；初次失败快照与最终快照均保留。控制台仅已有favicon.ico 404，无页面渲染异常。截图/快照：`ui-profile-no-cache.png`、`ui-profile-retry-final.png/md`、`ui-moments-dialog.png`，全部在本任务artifact目录。

## 安装前源码/设备漂移处理

2092 是本次首次冻结候选，已完成源码构建与固定重建但**未安装**。安装前发现手机实际已经由其他工作升级为 `0.3.85-debug/2092`，本地 main 同时新增 `662c7152`/`1d1db6aa`。root 检查新提交后整合到工作分支（merge `f5caf48f`），保留好友资料任意入口在线状态自取和两个平台下载链接按钮。重新选择 `0.3.86-debug/2093`，因此前表2452/29是2092阶段结果，最终2093验证另记，不把旧包证据冒充新包。

新 main 的 friendship 服务端改动属于已完成的其他任务，原始记录为`2026-09-12-presence-entries-and-links.md`；本次未部署服务端或执行迁移。工作分支合入这些既有源代码仅用于保留最新功能，不意味着本次重新验收它的历史生产发布。

## 最终2093验收与交付

最终源码提交 `01d6df58073a277e91edda7e1b1151a031402882`（已含 main `1d1db6aa`；首次修复提交 `bc28774b`）。本地分支 `codex/offline-recovery-20260912`。根工作区既有改动保留，本次未push/部署/迁移。

- 合并影响定向：74项通过、exit0；版本契约2项通过、exit0。两种平台下载链接的实际Clipboard内容有断言。首个新fixture漏传onInvite导致1失败，保留原失败日志后修正fixture，不当产品失败或成功证据。
- 最终分析：`merge-2093-analyze.log`，无问题、exit0。
- root最终完整Flutter：`flutter-full-2093.log`，**2453通过/29既有钱包失败**，exit1；`flutter-failure-comparison-2093.json`与既有基线失败差集为空。
- HTML/浏览器/契约输入未随此次合并或升号改变，复用上表159通过/11基线失败、真实DOM通过和28组件363屏通过。相关UI source diff已经亲审。`final-2093-inputs.json`记录最终Flutter差异输入，完整测试结束及构建后漂移均0。
- 标准ARM64 Debug源码构建 → Apktool2.12.1重建DEX/资源/manifest → zipalign16KiB → 固定签名 → 重新解包核验全部完成，`build-rebuild-2093-exit.txt`=0。源码/重建manifest语义相同，27250类一致，339项native/asset无内容变化；debug、包名、版本、ABI检查通过。
- 打包源含新main功能：最终kernel已检查包含`fetchFriendDetail`及安卓下载链接文案，且与未交付2092候选kernel SHA不同，详见`kernel-candidate-comparison.json`。
- 最终文件：`artifacts/2026-09-12/offline-recovery/delivery/debug-2093/final.apk`，143921451字节；SHA-256 **a4473e3965ec68f3aba499adadc4bc27c6b167053dab2b227ae27e2d92261b56**。
- 签名证书SHA-256：`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，与手机原包一致；v2/v3验证通过。
- Mi6 `cbd0156b`：`adb install -r` exit0/Success；安装后实际 `com.liuhetong.mobile`、`0.3.86-debug/2093`；首装时间仍2026-09-11 00:42:05，更新元数据2026-09-12 12:25:16。再次拉回base.apk，完整SHA与交付文件一致（`mi6-delivery-2093.json`）。未清数据、卸载、改网络配置或做功能测试。

验收状态：F1/C1/M2/M3/O1/O2/N1/U1的代码与自动化检查完成；真机短断网/切网≤5秒恢复、离线重进、视频/GIF连续复用、实际内存/帧率、iOS和多端场景仍按前述用例待用户验证。不能据安装成功声称功能真机验收通过。

时间：约10:45+08开始，12:26+08完成安装拉回核验，墙钟约101分钟。定位/实施/审查记录见任务文件；最终2093构建重建107.3秒（12:22:06.189—12:23:53.521），最终Flutter完整测试118秒。为保留并行main新增功能产生了一轮已说明的重新整合/验证/打包；各主动思考与工具重叠的精确耗时未单独测量，不将并行用时简单相加。Gradle已有插件KGP迁移/过时API提示记录在source-build.log，本次构建成功，未扩大升级推送或加密依赖。
