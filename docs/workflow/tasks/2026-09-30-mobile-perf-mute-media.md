# 0.4.25/2194 性能、静音与后台媒体

状态：Android 0.4.26/2195已生产发布；iOS同源候选预检超时后修复工作流，等待新CI及企业回签。用户授权实施、自主计划/ADR 和 Android 更新发布，后台下载包括后台与锁屏。
规格/计划：../../superpowers/specs/2026-09-30-mobile-perf-mute-media.md；../../superpowers/plans/2026-09-30-mobile-perf-mute-media.md。

输入：main 8e173178；已发布移动 0.4.25/2194，源码05c05793；iOS回签分发552a07a4已另案完成。主诉Android Redmi K80、5条/秒，没有具体时间。用户补充连续使用约15分钟后渐进卡顿，杀死重启好转；无法提供MB，按4500事件及反复切换进行回归。未取得K80真机测量。
开始：2026-09-30 22:38 +08 前已开始排查；以首个可靠时钟22:38为记录点。
工作树：C:/Users/Administrator/.codex/worktrees/mobile-perf-mute-media-2194/StarChat。

证据：根工作区 docs/verification/artifacts/2026-09-30/mobile-perf-mute-media/server-log-summary-v2.json（2026-09-30夜间，docker --since6h --tail20000，采样不完整）；服务器API001ddf336、Worker3efd5924，Synapse和syncworker健康。Android2194匿名诊断14批，70448帧、536超时、159构建/395绘制超时；不能逐一关联K80。抽样send p95 165ms/history105ms，无采样5xx；业务429需进一步按固定路由聚合，数值字符串关键词不能当HTTP状态。

已定位：GIF默认最多2个动画；偏好静音未写Matrix推送规则；客户端每个解密事件广播全量UI刷新；预下载依赖打开页面，缩略图完成触发父页面重建。
阶段记录（跨午夜，均为 +08）：
- 2026-09-30 23:32 前 Task2 定向65/65、analyze0；Task1代理94/94。实际起点未知，不按文件mtime估算工时。
- 2026-10-01 00:00 前独立Task1/2复核发现iOS silent继承默认声音、快速切换旧reload吞掉最后选择、旧mute迁移未撤销。新增四个行为失败用例后修复，61/61通过；例外范围说明红绿42/42。Task1/2复审无阻断发现。
- 2026-10-01 00:05 生产版本只读核对：两端仍0.4.25/2194，GitHub main仍8e173178；未发布任何本轮候选。HTML全量519通过，UI契约33组件/518屏PASS。
- Task3 Android原生编译和4个策略/传输/重启清理测试通过；命名空间、内容别名、密文身份、失败退役、账号释放和生命周期审查发现均已关闭。iOS macOS平台验证待新候选CI，没有真机证据。
- 2026-10-01 01:52 +08前：内存专项媒体66/66、SDK事件Box44/44、主代理预览/本地身份计数/最新时间线38/38通过；最终analyze无问题。真实SQLite4500条事件测试证明已落盘旧消息仍可回读，发送中/失败消息不裁剪。媒体与SDK独立审查通过；最新预览保护、身份计数独立及历史并发失效审查发现已补红绿关闭。
- 最终Flutter第一轮5201通过/9跳过/1失败：朋友圈取消发布时本地准备writer与目录释放竞争。新增两个确定性真实文件测试证明原竞态；屏障及并发取消合并修复后，相关59/59通过、分析无问题。01:55 +08前已启动修复后的完整共享门禁，结果待记录，不将首轮失败改写为通过。
- 2026-10-01 02:00 +08前：修复后完整Flutter **5204通过/9跳过，exit0，3分24秒**；最终完整analyze **No issues，exit0，8.9秒**；最终移动边界 **329通过/1跳过，exit0，30.06秒**。Moments与本地计数并发增量复审无剩余P0–P2，图片行缓存额外强引用假设被实际LayoutBuilder/Sliver生命周期否定，未加无必要补丁。02:00:35生产核对两端2194，main/origin仍8e173178，2195未占用。

内存归属：解密预览32/房间、1024全局、4MiB估算；SDK事件Box512条/4MiB估算（单条超过256KiB不留内存）；最新跟随时间线保留1000已确认事件及全部未确认/失败发送。首帧成功缓存8MiB/96、等待32、失败元数据192；大于64KiB的encoded图片键在最后消费者离开后退出Flutter decoded cache，头像最后成功provider200 LRU，poster清理同时释放revision。容量估算与单元测试不是Android RSS或GC实测，不认定单一路径为K80全部卡顿根因。

网络证据：注册路由样本中好友关联查询9271次；每秒5条的客户端回归用例从6次目录查询降至1次。Matrix send采样p95约165ms，历史约105ms；客户端和服务端不是逐请求配对，不能判定网络完全无问题。正常约30秒sync长轮询不计入服务器慢处理。旧API429样本尚未能绑定K80。

范围裁决：严格静音规则保留。用户再次开启提醒例外时，只承诺应用运行且收到并解密消息后评估；页面及HTML明确后台/锁屏不保证。没有为例外删除整房间静音规则。

未完成边界：iOS URLSession只继续已发现并登记的任务，尚未实现锁屏后新媒体事件的系统唤醒→Matrix同步→解密→登记链路。Android源码在现有保活服务存活时继续sync/source；ROM强杀、系统限额和实际K80锁屏未验收。不能将这一部分实现记录为两端锁屏新收件全部覆盖。

交付：源码`88bd1c4aed1793a683696e3a78b40c305af95afa`已合入main/push；1832移动输入冻结SHA`fa1ac7e42edfd8e5dbe8f99e63ffb6c8d10a7d909b6c81c6ebd9ed47987d4e6d`。2026-10-01 02:12:45 +08最终Android重建完成，81,914,910字节，SHA`f56d3cc19f4b36bd660421165ae4a4446542307e0f966c86cf78d9b8abf228b4`，固定cert75b31c66；25358类/338资产/清单语义/ARM64/原生锁屏/冻结输入门禁通过。第一次生成dev-only registrant引用失败110.5秒，按既有有界修正后重试成功，未改移动源码。

2026-10-01 02:40:35 +08启动正式Android发布，`PUBLISH_PASS`，trace `android-2195-20260930T184035Z`；私有备份 `/opt/starchat/docs/verification/artifacts/2026-09-30/mobile-perf-mute-media-2195-20260930T184035Z`。唯一release JSON SHA`826a5490b13880f652250e4ffa38b333ef765d2e4519515fd4401a0b0d8c6437`，发布脚本18离线+5真实隔离PG通过且独立安全复核通过。只变Android三键/三审计、下载页/registry/alias；iOS五键、两URL、两min=3、活admin-home及网络JS保留。2195新增CDN精确路径指向既有HTTPS香港源，CloudFront ETag CAS/Deployed/HEAD200/CORS通过；S3策略及四个旧failover路由原样保留，未宣称新包SG/S3主源上线。工作站严格TLS HEAD和小元数据SHA通过，匿名更新接口401；实际路由函数只读投影Android2195/iOS2194通过（不是已登录真机HTTP验收）。暂存SSH偶发kex拒绝与SG Python3.9私有解包验证兼容错误均保留，后续恢复在私有输入逐字校验后执行，没有覆盖未知公态。

iOS首轮CI`36756076089`源码88bd：simulator-preflight 18:05:39–18:42:52 UTC，35分钟预算取消，IPA build skipped。日志证明SQLCipher4/Keychain1/通知1通过；raw XCTest切独立目录并双架构重复编译，18:39:06完成Runner Touch但取消前无XCTest结果。不能认定唯一原因是编译，也不能声称新native媒体/Nav测试通过。7行工作流补丁复用BUILD_DIR、当前模拟器架构并预算45分钟，保留全部检查与signed build；4静态合同RED2fail→GREEN4pass，YAML/bash语法/独立复核通过，下一轮Mac仍必需。Android源码/包不因此重建。

Android CI`36756076135`的Flutter analyze/test及debug native build通过；infra失败与基线`36727389885`逐字同一`test_singapore_edge.py::test_render_uses_file_secret_and_blocks_internal_peer_networks` owner-only fixture错误，相关infra/services/CI inputs无改动，不称整体CI通过、不降低秘密权限检查。

下一步：提交iOS工作流及已发布下载元数据/台账，触发新同源iOS CI；通过后下载原始候选IPA交企业回签，旧2194例外不可复用。K80持续15分钟/后台与锁屏真实RSS及动画验收待用户更新后反馈。
限制：无真机；iOS系统后台调度和企业回签只阻塞对应平台验证/发布，不阻塞Android代码修复。
