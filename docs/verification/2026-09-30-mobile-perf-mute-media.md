# 2194 性能、静音与媒体修复验证（Android2195已发布）

授权、恢复步骤与独立范围见[任务记录](../workflow/tasks/2026-09-30-mobile-perf-mute-media.md)、[规格](../superpowers/specs/2026-09-30-mobile-perf-mute-media.md)、[计划](../superpowers/plans/2026-09-30-mobile-perf-mute-media.md)。工作树基线 main `8e173178`。截至2026-10-01 02:53 +08，Android `0.4.26+2195` 已生产发布，iOS仍2194；首轮iOS原生CI超时，无新IPA，工作流修复已通过增量审查。

## 日志证据与归因边界

只读既有SSH跳板，服务器聚合脚本不输出消息内容、账号标识、URL参数、令牌或密钥。`docker --since6h --tail20000/30000` 是有截断的样本；匿名 Android2194 14批诊断70448帧、536慢帧，其中159构建/395绘制慢帧可重叠。用户指定Redmi K80/5条每秒，没有具体发生时间，不能把全部样本绑定到该机。

Matrix send330次样本p95约165ms，history3274次p95约105ms，media74次p95约32ms；约30秒sync是长轮询等待，不能视为服务器处理30秒。未见该样本5xx；另一API样本429共236次，但无法按同一请求绑定K80。客户端发送p95约2946ms和服务器send耗时不是逐请求配对，不能相减为纯UI/网络耗时。

已定位客户端每次消息更新都刷新目录：业务注册路由好友关联GET9271次。红用例5次消息更新触发6次关联查询、期望1；节流后1次。消息到达后的页面刷新、身份映射、缩略图解码会占用与动画共享的Dart/UI或raster预算，因此网络回调和消息处理可能影响动画；网络请求本身的异步等待不等于阻塞UI。此次不声称服务器性能或网络完全无问题，也不声称已经实测K80动画恢复。

## 实现与测试

- UI快照按16ms合并，逐个解密事件和发送确认不合并。缩略图完成只失效媒体行；键盘、无关父刷新保留消息行/输入组件。默认所有可见GIF可同时动画，显式预算与离屏/后台暂停仍保留。Task2聚焦65/65、analyze0。
- 静音同时写本地账号偏好与自有Matrix `dont_notify` 规则，离线耐久重试、取消静音与旧偏好迁移。快速连续选择保留最终意图；可选成员刷新失败不会反转已保存选择；iOS silent显式关闭alert/sound。Task1初始94/94；独立审查新增四个红用例后61/61；范围文案回归42/42。
- 未进入页面也发现逐个已解密图片/GIF/视频及Moments最新媒体；原生传输只处理密文/受控业务媒体，Matrix解密与摘要校验仍在SDK本机。账号撤销取消任务，闪照排除，交互保留调度槽。Task3最终Android编译/4原生测试通过；独立审查发现的预览命名空间、同内容事件别名、密文身份、永久失败退役、生命周期、账号lease释放与重启孤儿文件限额均已关闭；视频poster首帧与重入聚焦48/48及35/35相关回归通过。
- HTML全量519通过；移动边界329通过、1跳过（内存输入最终重跑中）；UI契约33组件/518屏PASS；候选升版三项契约PASS。完整analyze最终无问题。早期完整Flutter在2275通过/9跳过/14失败时主动取消，真实exit1：新增source未登记架构清单、Moments退出定时器竞争、旧目录回调字符串断言；保留日志，不称完整通过。最终第一轮5201通过/9跳过/1失败，朋友圈取消上传本地writer与目录释放竞争；新增两个真实文件RED回归后修复，相关59/59及分析通过，独立复审无新P0–P2。修复后完整共享门禁运行中。
- 完整 `verify.ps1` 预检在缺少本地 `.env` 时exit1；未导入生产配置制造通过。Repository/Deployment policy与模板步骤已执行，API/Worker源码无改动，依赖同输入门禁；此报告不称全仓脚本通过。

Windows PowerShell7、Flutter3.44.9/Dart3.12.2、Gradle9.1.0；pubspec锁SHA256 `314504b9bf3917b30a6e12b3262eca23f774a43e4b23a88a801ae35bbea76bf3`。原锁恢复后PUB_HOSTED_URL=pub.dev且pub get --enforce-lockfile，未升级依赖。全部原始日志在本任务 `artifacts/2026-09-30/mobile-perf-mute-media/`。

## 用户追加的内存专项

用户报告约15分钟逐渐卡顿、重启好转，无MB值。真实SQLite4500条及媒体缓存用例用于证明引用增长和预算，不能等同K80 RSS/GC采样。

解密预览原4500事件保留4501份JSON副本；现在32/房间、1024全局、4MiB估算，保护当前最新预览，身份择房改用独立耐久fragment计数。历史分页、账号连续性及await期间历史失效均有红绿回归。最新跟随时间线裁剪至1000已确认事件，保留全部pending/error；4500条落盘记录仍可从SQLite读取，锚定历史及分页/解密中不裁剪。主代理最终8文件38/38通过。

SDK `box_events` 原持续保留每条get/put/getAll结果，新增512条/4MiB估算LRU，超过256KiB的单条不留内存；真实SQLite覆盖负缓存、4500收件、事务pending读优先和删除/再写，不改其他加密账号/状态Box策略。7个相关测试文件44/44通过，独立复核输入清单SHA `f8533049521b1d089a97bf65fe155b4ead8fec2f98ea1eff3ff2a36dcfae68db`。

视频首帧成功Future原全局无界保留，改为8MiB/96 LRU、等待32、失败元数据192。Flutter ImageCache只统计解码像素，MemoryImage key会额外保留encoded bytes：24个1px GIF实际保留3146808字节，修复为大于64KiB的key在最后listener退出后evict，已挂载消费者与可见GIF持续动画保持。头像最后成功provider200 LRU；poster clear同时清revision。9文件66/66通过、分析0，独立复核输入清单SHA `49f2ca6e89c82ce483c2b90062c293b86980d2a0a061e1505f1b7a73d4e28227`。

另只读检查RoomPage行缓存：两处initialBytes在LayoutBuilder.builder中求值，缓存Widget并不保留生成的图片Element；超出Sliver缓存区且无keepalive时卸载。没有证实该处有额外预算旁路，未增加重复懒回调。以上未测得真机RSS下降，也不声称所有进程内存来源均有界。

## UI与审查

例外设置页说明“仅在应用运行并收到消息时提醒；后台或锁屏不保证提醒。”；普通静音继续禁止普通后台声音/弹窗。手动开启例外依赖运行中客户端安全解密，不宣传后台例外已经实现。独立Task1/2规格及质量复核无剩余阻断发现。

Figma已退役：本次仅更新HTML demo `frontend/index.html?screen=chat-group-info-default`，registry `packages/ui-contracts/changliao-component-registry.json` 的 `2026-09-30-mute-exception-scope`；复用既有TextSecondary/spacing token，无新增颜色/尺寸。2026-10-01 00:08本地浏览器视觉核对说明完整换行、无裁切；截图 `mute-scope-demo.png`。临时localhost19595与浏览器验证页已关闭。

## 未完成验收与平台边界

Android源代码保持既有foreground服务存活时Matrix sync/source运行，可发现锁屏新收件；没有实际K80锁屏、厂商强杀或系统限额验证。iOS系统后台URLSession只保证已登记任务在允许调度时继续；挂起后才新收到媒体的唤醒→sync→解密→登记链路未实现，Moments挂起新帖亦不能保证即时发现。本轮不添加NSE、不迁移密钥、不放宽E2EE。iOS macOS编译/XCTest、候选IPA、企业回签及真机尚未完成，2194精确回签差异授权不得复用给2195。

最终共享门禁：2026-10-01 02:00 +08前，`flutter-full-memory-final-green.txt` **5204通过/9跳过，exit0，3分24秒**；`analyze-release-final.txt` **No issues，exit0，8.9秒**；`mobile-contracts-memory-final.txt` **329通过/1跳过，exit0，30.06秒**。Moments取消与计数并发增量审查已关闭全部确认P0–P2。02:00:35 +08只读生产核对仍两端2194、min支持3；main/origin仍8e173178。

## Android实际发布

源码main `88bd1c4aed1793a683696e3a78b40c305af95afa`，冻结1832输入SHA `fa1ac7e42edfd8e5dbe8f99e63ffb6c8d10a7d909b6c81c6ebd9ed47987d4e6d`。02:12:45 +08最终APK **81,914,910字节**、SHA `f56d3cc19f4b36bd660421165ae4a4446542307e0f966c86cf78d9b8abf228b4`，cert `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。Apktool2.12.1→zipalign→固定签名；25358类、338资产及manifest语义相同，ABI/DEX/资源/原生lock/freeze门禁通过。详见`android-release/run-20261001-020600/artifact.json`及`steps.tsv`；dev-only registrant首轮失败有界修正重试后通过，不称第一次构建成功。

02:40:35 +08启动受控发布，`hk-publish.jsonl`记录 **PUBLISH_PASS** 和十键readback；Android0.4.26/2195及更新说明已启用，iOS仍0.4.25/2194，两min支持3。私有备份/trace见任务记录。唯一release SHA `826a5490b13880f652250e4ffa38b333ef765d2e4519515fd4401a0b0d8c6437`；18离线、5真实PG事务/并发/回滚通过，独立规格/安全复核接受。新增CDN2195 exactpath仅指向现有HK HTTPS源，旧S3 policy/四条failover/OriginGroups原样，避免无CAS policy覆盖。CF ETag更新/Deployed、HEAD200/size/MIME/CORS通过；HK/工作站双侧严格TLS及小元数据SHA、匿名401、实际只读路由函数平台投影通过。没有公开完整APK回拉，没有真机安装/RSS/动画验收。

[正式APK](https://www.liuhetong888.com/downloads/ChatFlow-0.4.26-build2195-arm64.apk)，[分发页](https://www.liuhetong888.com/download?platform=android&install=1)。现网admin-home/三个网络JS/iOS manifest未写，来源未知钱包变更通过活文件hash保护。

Android CI`36756076135`移动分析/测试/native debug通过，infra整体失败已对比基线`36727389885`相同owner-only secret fixture错误且对应输入未变；日志`infra-ci-2195.log`/`infra-ci-baseline.log`，不称整体CI通过。

iOS原始CI`36756076089`35分钟预检取消、build skipped，原生SQLCipher4/Keychain1/通知1已通过，raw XCTest结果缺失。工作流7行补丁仅复用当前sim架构/BUILD_DIR并45分钟预算，保留全部gates；4合同红绿、YAML/bash与独立复核通过。日志/证据`ios-preflight-diagnostic/`。Mac新CI、候选IPA、企业回签及锁屏新收件链仍待办，不复用2194单包例外。下一步提交此有界工作流修复并等待真实Mac结果。
