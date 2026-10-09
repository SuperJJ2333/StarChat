# Android 0.4.35+2204 正式发布与更新弹窗

## 恢复入口

- 用户授权：在已说明2204会话debug红屏尚未修复后，用户明确要求“发布Android的最新版本，并且推送更新弹窗”。本任务发布已验收的正式ARM64 release成品0.4.35+2204，并启用既有App版本检查的普通更新提示；可跳过，最低支持build按当次线上值保持。不把“弹窗”解释为新增OS push或发送其他消息。
- 授权边界：仅Android包分发、对应下载入口与更新设置；没有iOS发布、main合并/推送、业务/Matrix服务部署或金融操作授权。常规发布与更新弹窗已获直接授权，不再重复申请。
- [计划](../../superpowers/plans/2026-10-07-android-2204-release.md)、[移动交付工作流](../../runbooks/mobile-delivery-workflow.md)、[轻量发布门禁](../../runbooks/release-metadata.md)、[前修复任务](2026-10-07-history-icons-performance.md)、[独立红屏调查](2026-10-07-room-lifecycle-assertion.md)。前任务“无正式发布”的表述是当时快照；本次新授权与发布单独记录，不覆盖历史证据。
- 当前状态：**Android0.4.35+2204已正式上线，普通可跳过更新提示已配置；R1–R6通过；源码、台账与索引已在本次证据分支提交，未merge/push main**。20:43:09–17发布PUBLISH_PASS，20:43:24–30四项当次后验全部exit0；真机收到提示/覆盖升级和原弱网快滑场景仍未验收。前态与后态分别记录，不以历史2202或18:51资源指标替代。
- 负责人/文件所有权：root负责当次生产基线、发布记录、受控上传/切换、读回与索引前插；lifecycle_record仅拥有本新任务和本新计划两个文档。主区`D:/pythonProject/outsource/StarChat`原1373项WIP保留，不从整份脏源码发布。现成成品源码为`3a620495ae048d3e4141f099e1926ecedc8669cd`，不是主区main的未提交内容。
- 已知限制：用户会话红屏`framework.dart:6268 _dependents.isEmpty`首因仍未确认，尚无有效缺陷RED或生产修复；debug会显示断言，release不显示红屏不能证明缺陷已修复。此正式包包含前任务图标/历史/同步计时修复，不能宣称包含随后红屏的根因修复。
- 最后更新时间：2026-10-07T20:47:19.832+08:00；各项生产观察时间另列。
- 下一步：本次发布无需重复；继续独立红屏首异常调查，并分别收集真机弹窗、覆盖保留数据及弱网快滑反馈。实际用户设备验收未执行，不把release隐藏断言当修复。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| R1 | 读取当次生产前态、2204未被其他任务占用、明确Android范围及回退 | 完成当次freeze/安全投影；21发布已生成宿主机0700备份 | HK20:20:18前态2202/2194/min3/schema0095/35running、当时目标不存在；SG20:20:21前态Deployed/7routes；前态投影和21发布均exit0 | 已完成后续切换，前态供恢复 | 无 |
| R2 | 精确发布已受验0.4.35+2204正式ARM64 APK，资源/原生/签名身份保持 | 成品预检/上传完整性/公共安装完成，不重建 | 20:21:22–24身份/签名/P16 PASS；逐块/整包SHA、16安装及postflight通过，旧实际包双审身份与本次精确SHA匹配 | 精确成品已上线 | 手机未覆盖安装，不把模拟器debug安装当正式包验收 |
| R3 | 不可变APK可下载，实际双路/别名/站点入口一致，旧包可回退 | 完成：公共immutable、仅新HK-origin CDN路由/Deployed、latest-arm64切2204、页面/registry上线 | execution16–20各exit0；工作站严格TLS direct/CDN/latest HEAD200/82848798/MIME及CDN CORS通过；372byte registry/8354byte页面SHA匹配，旧immutable/旧7routes保留 | 已正式分发 | HEAD/小元数据不证明手机安装或源码已解决后续红屏 |
| R4 | 既有App更新检查提示2204，自动弹窗和手动检查使用相同Android路由；普通可跳过 | 完成：20:43:09–17事务CAS三键/审计PUBLISH_PASS；仅version/build/notes变更 | 预审SPEC→QUALITY接受；runtime route.endpoint+SettingService读回Android2204/iOS2194/无platform默认Android、exact3audits；公开HTTP三platform401；min3/bridge/iOS五键保持 | 提示已配置 | 源码在下一启动/前台检查评估新版本；authenticated real-user HTTP、设备收到提示/覆盖安装NOT_EXECUTED；无新增OS push |
| R5 | iOS设置/版本/包/强更策略、业务/Matrix容器和非本次静态内容保持 | 完成：后态与当次前态精确比较 | HK exact十键、iOS五键/min3/schema0095、5保留静态及other ABI alias保持；所有35容器id/image/restart/start完全相同；SG exact8routes/旧7保全/策略不变/Deployed | Android范围隔离通过 | 无iOS发布；共享下载页的Android两字段变化不称整个共享页面字节未动 |
| R6 | 证据/新任务/索引有身份且可恢复，原WIP保全 | 当次发布/后验归档；源回填/索引/1373原WIP保全证明完成；最终有序review及证据分支提交已完成 | primary Node57/managed Node54/managed Python32 GREEN；10份before/inverse逐字节PASS；两区索引各前插1434byte原tail完全保持；main不merge/push | Android发布与源/记录交付完成 | 手机真实覆盖/弱网快滑/图标/卡顿及红屏根因调查仍缺，不因发布关闭 |

## 版本与证据

| 平台/服务 | 实际版本/build | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/状态 |
| --- | --- | --- | --- | --- | --- |
| 本地正式成品 | 0.4.35+2204；standard ARM64 AOT release | `3a620495ae048d3e4141f099e1926ecedc8669cd` | `com.liuhetong.mobile`；固定`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，v2/v3单签 | [APK](../../verification/artifacts/2026-10-07/history-icons-performance/delivery/ChatFlow-0.4.35-2204-arm64-release-rebuilt.apk)，82848798bytes，SHA`a2d100be2e0273107d231dfd82fee316c89d3c1cb37ff976ba36d8f2fcf835e5` | [成品身份](../../verification/artifacts/2026-10-07/history-icons-performance/delivery/artifact-arm64.json)为19:03接受的历史记录；本次21发布及postflight已独立证明上线 |
| 本次正式Android前态 | 0.4.33+2202；min3 | 前态注册成品SHA`0e5255a631ceb37c6556f08caf1b7199637d85c5ea6bd050c49cf6d2f8e642c2` | 当时`latest-arm64.apk`→2202；bridge入口 | [HK当次安全快照](../../verification/artifacts/2026-10-07/android-2204-release/live-preflight/hk-live-snapshot.json)，旧包82193438bytes；当时2204目标不存在 | 20:20:18.168815+08前态快照，20:43后态另行列出，旧包保留 |
| iOS/业务服务前态 | iOS0.4.25+2194/min3；schema`0095_wallet_source_alerts`；35running容器 | 运行image/id/restart/start白名单在HK快照中冻结 | iOS下载入口/notes/强更当次前态 | [设置前态](../../verification/artifacts/2026-10-07/android-2204-release/live-preflight/settings-before.json)及HK快照；后续HK postflight已证明精确保持 | 20:20:18.168815+08前态；本次无iOS发布或服务部署 |
| 当次SG分发前态 | CloudFront Deployed，ETag`E1VC38T7YXB528`，7旧路由 | 当前DistributionConfig/策略白名单冻结 | 2204尚无新路由 | [SG当次安全快照](../../verification/artifacts/2026-10-07/android-2204-release/live-preflight/sg-live-snapshot.json) | server checked_at 2026-10-07T12:20:21.268739Z＝20:20:21.268739+08 |
| 本次正式Android后态 | **0.4.35+2204；min3，普通可跳过提示** | 精确受验`3a620495ae048d3e4141f099e1926ecedc8669cd`成品；没有新源构建 | `com.liuhetong.mobile`/原固定75b31；`latest-arm64.apk`→2204；bridge URL保持 | [正式直链](https://www.liuhetong888.com/downloads/ChatFlow-0.4.35-build2204-arm64.apk)及[CDN](https://d12fjr06o6tga5.cloudfront.net/downloads/ChatFlow-0.4.35-build2204-arm64.apk)，82848798bytes/SHAa2d100be…fcf835e5 | 20:43:17.110974+08发布exit0/PUBLISH_PASS；20:43:24–30独立后验均exit0 |
| iOS/运行/CDN后态 | iOS0.4.25+2194/min3保持；schema0095/所有35运行身份保持；CDN Deployed/8routes | 旧7route/策略保持；新增精确2204 HK-origin route | iOS五键、其他ABI alias及5保留静态按当次前态不变；CDN ETag`E2EUQ1WTGCTBG2` | postflight HK/SG结果见下方；没有iOS发布或服务重启 | 20:43:27.827356/20:43:30.570328+08后验exit0 |

### 证据复用和当前未执行项

- [前修复完整报告](../../verification/2026-10-07-history-icons-performance.md)、[ARM64构建身份](../../verification/artifacts/2026-10-07/history-icons-performance/android-arm64/run-20261007-185625/artifact.json)：Flutter3.44.9/Dart3.12.2、Windows/pwsh7 UTF-8，源freeze1881输入manifest SHA`76d10524056a5efe9da34f679bd3b69de046859d9f67a372a0f13883b9f8d840`，锁SHA`ac0966cb75f61763073bfc48ef5e8b93b85cf6cf46ebaa921d8b3739c62694ac`。完整Flutter5501 PASS/9skip/0FAIL、analyze0、移动Python354 PASS/1skip、原生59 PASS按不变输入复用，详尽命令/真实退出码/失败重试与工具身份见前报告。
- ARM64 run18:56:25.638–18:59:01.703+08各step exit0，源码构建→Apktool2.12.1常规DEX/资源/manifest重建→build-tools36.0.0 P16对齐→固定签名；完整字体/emoji/SVG、319 Flutter成员、310声明资源及338原生资产保全，19:03:49实际SPEC→QUALITY接受。无Dart/R8混淆，无字体裁剪。本次使用同一成品，不重建、不重复不变移动源码全量或实际APK解包门禁。
- 本次内容/传输完整性、设置/路由/分发/审计与平台隔离均使用本次实际回执通过，详见下方；没有用历史PUBLISH_PASS顶替本次结果。手机/实际用户鉴权HTTP和红屏根因修复仍未验收。
- 本次当次前态证据：[HK投影命令/时间/exit0](../../verification/artifacts/2026-10-07/android-2204-release/live-preflight/hk-projection-metadata.json)、[SG投影命令/时间/exit0](../../verification/artifacts/2026-10-07/android-2204-release/live-preflight/sg-projection-metadata.json)。两者本地同时开始20:20:24.023906+08，分别20:20:27.007843/20:20:29.561029结束；保存仅公共settings/hash/运行身份等白名单，不保存或输出原始含环境secret的容器inspect。
- 本次独立成品预检：[fresh-delivery-preflight.json](../../verification/artifacts/2026-10-07/android-2204-release/preflight-review/fresh-delivery-preflight.json)，20:21:22.2644279–20:21:24.4098075+08，`EXACT_ACCEPTED_ARM64_DELIVERY_ARTIFACT_PREFLIGHT_PASS`；identity/signature/alignment各exit0，精确SHA/bytes/source与本任务相同，物理手机安装NOT_EXECUTED，本次生产写入NOT_PERFORMED。本次对本地成品身份/签名/P16作轻量前检，没有源码重建、完整回归重跑或公网包回拉。
- 当次准备：[PREPARATION-REPORT.md](../../verification/artifacts/2026-10-07/android-2204-release/publish-prep/PREPARATION-REPORT.md)记录身份替换/AST等价、原SettingService事务保持、离线30PASS/0skip/exit0。最终[release.json](../../verification/artifacts/2026-10-07/android-2204-release/publish-prep/prepared-2204/release.json)SHA`44ae1e45ba6dbf0647601de6126ef46c2b3ce8528fc3e8be22bed1e7a6dad5db`；[runtime-2204.tar.gz](../../verification/artifacts/2026-10-07/android-2204-release/publish-prep/runtime-2204.tar.gz)SHA`dae5ec05d8a0b0a5ebb0d8d93a7e78b1dfa9b366ea6866010c856279e8e44211`；[freeze-manifest.json](../../verification/artifacts/2026-10-07/android-2204-release/publish-prep/freeze-manifest.json)SHA`3a11022de11226a84d03f4d0e7a2f1707ce2c7e4fdeeeb2c28745cf54f6d97cf`。旧notes payload和CRLF转换返工失败留作历史，不作最终接受；冻结后不得再生成改变输入。
- 当次隔离真实PostgreSQL：[05-real-postgres-cas.json](../../verification/artifacts/2026-10-07/android-2204-release/execution/05-real-postgres-cas.json)，20:26:33.831027–20:26:40.301930+08，执行标记`05-real-postgres-cas`绑定`test_settings_postgres_2204.py`，**6 PASS/5.47s、真实exit0**。使用digest固定PG16.9和localhost随机隔离容器并清理，没有生产DB写入；具体完整shell参数未在该JSON单独记录，不据此伪写命令。
- 私有传输/合并：[execution目录](../../verification/artifacts/2026-10-07/android-2204-release/execution/)01–04记录0700HK暂存、5块顺序上传/逐块SHA与manifest全部exit0；[13-assemble.json](../../verification/artifacts/2026-10-07/android-2204-release/execution/13-assemble.json)20:29:51.633586–20:29:53.395738+08整包a2d100…精确exit0。06–10记录相同runtime SHA上传/提取HK/SG全部exit0，11/12实际HK release/SG delivery help各exit0；[14-cdn-precheck.json](../../verification/artifacts/2026-10-07/android-2204-release/execution/14-cdn-precheck.json)20:29:51.633586–20:29:57.202413+08，当前before/Deployed/新鲜ETag/策略保持exit0。以上无公共immutable、CDN新路由、alias/页面或三键写入。
- 当次独立有序预审：[publication-acceptance-metadata.json](../../verification/artifacts/2026-10-07/android-2204-release/preflight-review/publication-acceptance-metadata.json)，SPEC20:40:28.8920111+08接受→QUALITY20:40:28.9197325接受，绑定record44ae1e45…和runtime dae5ec05…（45553bytes）；预审本身不证明生产上线，以下实际执行另绑定。
- 公共执行：[16 immutable安装](../../verification/artifacts/2026-10-07/android-2204-release/execution/16-hk-immutable-install.json)、[17 CDN安装](../../verification/artifacts/2026-10-07/android-2204-release/execution/17-cdn-install.json)、[18 Deployed检查](../../verification/artifacts/2026-10-07/android-2204-release/execution/18-cdn-deployed-check.json)、[19 alias切换](../../verification/artifacts/2026-10-07/android-2204-release/execution/19-hk-alias-switch.json)、[20最后前态检查](../../verification/artifacts/2026-10-07/android-2204-release/execution/20-final-prepublish-check.json)、[21 publish](../../verification/artifacts/2026-10-07/android-2204-release/execution/21-publish.json)均exit0，时间见阶段表。21为**PUBLISH_PASS**，trace`android2204-20261007-202800`，宿主机0700备份`/opt/starchat/docs/verification/artifacts/2026-10-07/android-2204-202800`。只写Androidversion/build/notes三键，保留bridge/min3/iOS五键。
- 四项并行后验：[HK](../../verification/artifacts/2026-10-07/android-2204-release/postflight/hk-result.json)、[SG](../../verification/artifacts/2026-10-07/android-2204-release/postflight/sg-result.json)、[runtime路由/审计](../../verification/artifacts/2026-10-07/android-2204-release/postflight/route-result.json)、[工作站HTTPS](../../verification/artifacts/2026-10-07/android-2204-release/postflight/https-result.json)，20:43:24.868712+08起，分别20:43:27.827356/20:43:30.570328/20:43:27.718631/20:43:27.861300结束，全部exit0。HK精确设置/schema0095/5保留静态/其他alias及35容器id/image/restart/start保持；SG exact8routes/旧7保持/策略不变/Deployed；运行route.endpoint+SettingService投影Android2204、iOS2194、legacy默认Android，恰好3匹配审计。严格TLS SOCKS direct/CDN/latest HEAD200、82848798bytes/MIME、registry372bytes/page8354bytes SHA一致，`/api/v1/app-updates` Android/iOS/legacy公开HTTP均401。`authenticated_user_http`和`physical_device_prompt`均NOT_EXECUTED，公网完整APK下载0；不把这些服务端结果等同于真实用户HTTP/已收到弹窗或覆盖安装。
- 源回填：[SOURCE-BACKFILL-REPORT.md](../../verification/artifacts/2026-10-07/android-2204-release/source-backfill/SOURCE-BACKFILL-REPORT.md)、[source-audit.json](../../verification/artifacts/2026-10-07/android-2204-release/source-backfill/source-audit.json)。两个页面各自仅替换Android直链与script revision，保留primary Orbit和managed既有不同UI；registry六身份字段及相关fixture受控回填。primary Node57/57、managed Node54/54、managed Python32/32均exit0/0skip，工具Node22.22.2/Python3.12.10；前置fixture版本RED4/3有效。managed旧warning fixture基线同FAIL已证，随后仅对齐现有更强文字，不改iOS页面。10份before/inverse逐字节PASS，实际文件SHA在source-audit内；47冻结文件/22runtime entries仍精确。
- 索引/WIP：[closeout-preservation.json](../../verification/artifacts/2026-10-07/android-2204-release/closeout-preservation.json)20:46:01.431343+08；两区current-state各前插1434byte，原tail逐字节相同。primary最初1373项只授权`frontend/download.html`两字段及current-state三次前插存在delta，逆变换原hash准确；其余原字节完全保全、无意外变化，main仍be207f0fece77f0a4585790d7c0932368ac63146，未merge/push。
- 隧道关闭：[22-tunnel-closed.json](../../verification/artifacts/2026-10-07/android-2204-release/execution/22-tunnel-closed.json)20:44:26.6504261–20:44:28.6254907+08，root自建ssh PID32776/loopback18947关闭，listener_count_after0；exec session45565随后-1为本次有意关闭，不是新的生产故障。
- 前任务`verify.ps1`缺`.env/local.env`未执行，不引入生产秘密；本次没有产品源变更，不重新运行该环境缺失门禁。新iOS构建/IPA与手机正式包覆盖安装均未执行。
- 新证据仅放主区`docs/verification/artifacts/2026-10-07/android-2204-release/`。HK私有暂存`/opt/starchat/releases/android2204-20261007-202800`、SG私有暂存`/home/ec2-user/starchat-android2204-20261007-202800`均0700；21实际创建宿主机0700发布备份`/opt/starchat/docs/verification/artifacts/2026-10-07/android-2204-202800`，不把容器`/tmp`作唯一备份。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 用户新发布授权与root恢复 | 精确开始未知 | 当次基线前恢复已完成 | 主动 | root / release preparation | 不从聊天顺序或文件mtime估精确时间 | 当前生产后态已完成 |
| 新任务/计划文档 | 2026-10-07T20:18:27.599+08:00 | 20:47:19.832+08事实收尾 | 主动/阶段更新 | lifecycle_record | 本地Get-Date；持续按root实际回执更新 | 简短链接/编码校验后交root |
| 当次生产观察 | server HK20:20:18.168815+08 / SG20:20:21.268739+08 | 当次快照已取得 | 工具 | root | 2202/2194、两min3、schema0095、35running、SG Deployed7旧路由、当时2204不存在 | 21及postflight已完成后态/备份 |
| HK/SG安全前态投影 | 2026-10-07T20:20:24.023906+08:00 | HK20:20:27.007843；SG20:20:29.561029+08 | 并行工具 | live freeze | 两命令exit0；区间并集5.537123s，不把两耗时相加 | 用这次前态生成CAS运行件 |
| 精确本地正式成品预检 | 2026-10-07T20:21:22.2644279+08:00 | 2026-10-07T20:21:24.4098075+08:00 | 工具 | artifact preflight | SHA/身份/签名/P16预检PASS，2.1453796s | 不变源/包复用；传输及公共安装已完成 |
| HK私有0700暂存 | 2026-10-07T20:26:16.080760+08:00 | 2026-10-07T20:26:17.348177+08:00 | 工具 | root private stage | execution01 exit0；不是公开安装 | 顺序上传已完成 |
| 五块顺序传输/核验/manifest | 2026-10-07T20:26:17.358280+08:00 | 2026-10-07T20:28:30.283831+08:00 | 工具 | upload；与PG并行 | execution02/03各5块及04全部exit0 | 后续预审及16公共安装均已完成，旧包保留 |
| 真实隔离PG CAS | 2026-10-07T20:26:33.831027+08:00 | 2026-10-07T20:26:40.301930+08:00 | 工具 | isolated PG；与upload并行 | 六PASS/5.47s/exit0；无prodDB | 20:40有序预审接受，21发布已完成 |
| runtime HK/SG传输/提取及实际CLI | 2026-10-07T20:29:27.469730+08:00 | 提取20:29:36.076351；help20:29:43.256971+08 | 工具 | root runtime stage | execution06–12全exit0、同runtime SHA；help并行 | 冻结输入不得变更 |
| 精确整包合并/SG前态复检 | 2026-10-07T20:29:51.633586+08:00 | assemble20:29:53.395738；cdn-precheck20:29:57.202413+08 | 并行工具 | assemble / cdn-precheck | 13/14均exit0；a2d100…精确/before模式保持 | 后续有序预审及16–21公共发布均已完成 |
| 当次有序独立预审 | SPEC2026-10-07T20:40:28.8920111+08:00接受 | QUALITY20:40:28.9197325+08接受 | 审查 | independent review | record/runtime绑定、两项接受；此前等待/返工时段未精确细分 | 后续公共执行已通过 |
| 公共immutable安装 | 2026-10-07T20:40:47.452645+08:00 | 2026-10-07T20:40:50.694036+08:00 | 工具 | root | execution16 exit0；此时alias仍2202 | CDN安装/等待已完成 |
| CDN安装/等待Deployed | 安装20:40:56.992394+08 | 安装20:41:13.215908；Deployed检查20:42:33.005730–20:42:39.494705+08 | 工具/外部等待 | root CDN | 17/18均exit0；InProgress→Deployed，HEAD/MIME/CORS通过 | alias切换已完成 |
| alias切换/最后前态检查 | alias20:42:47.330161+08 | alias20:42:50.516162；最后检查20:42:58.216794–20:43:01.495549+08 | 工具 | root | 19/20 exit0；alias2204，静态/settings仍exactbefore | publish已完成 |
| 页面/三键设置发布 | 2026-10-07T20:43:09.357954+08:00 | 2026-10-07T20:43:17.110974+08:00 | 工具 | root publish | 21 exit0/PUBLISH_PASS/trace及0700备份 | 后验已通过 |
| 四项后验 | 2026-10-07T20:43:24.868712+08:00起 | HK27.827356/route27.718631/HTTPS27.861300/SG30.570328（20:43+08） | 并行工具 | HK / SG / route / HTTPS | 四exit0；完整区间并集约5.702s，不相加 | 源回填/索引已完成；仅最终review/分支提交 |
| 源回填Node专项 | primary20:40:34.2541254/managed20:40:34.2570752+08 | primary20:40:43.4632358/managed20:40:43.4634988+08 | 并行工具 | source backfill | primary57/managed54 PASS、exit0；先RED4/3 | managed Python后续通过 |
| managed Python/源逆变换审计 | Python20:42:27.6288269+08 | Python20:42:28.3919957；审计20:44:49.729995+08 | 工具 | source backfill | Python32PASS/exit0；10份before/inverse PASS | 原WIP全局保全20:46完成 |
| 自建隧道关闭/索引保全 | 关闭20:44:26.6504261+08 | 关闭20:44:28.6254907；索引检查20:46:01.431343+08 | 工具/主动 | root closeout | listener0；两区1434byte前插tail保持、原1373逆变换证明 | 最终有序review及本分支提交已完成 |

总墙钟：本次发布和源/记录交付完成；精确授权/恢复起点未知，不估算总墙钟。前任务构建和测试耗时只作复用证据，不重复计为本次执行时间；并行区间不累加。

## 交接与回退

- 当前已构建/已上线/未真机验收：精确ARM64成品已受验并已正式发布，普通更新提示配置/服务端投影及公网门禁通过。实际用户鉴权HTTP、手机收到提示/覆盖保留数据、弱网快滑/图标/卡顿尚未验收；红屏首因仍未知，发布release不能算根因修复。
- 发布次序：先受控落不可变文件并确认下载可用，再切相应别名/页面，最后通过公共SettingService事务CAS及审计仅更Android`app_latest_version`/`app_latest_build`/`app_update_notes`三键。`app_apk_url`既有bridge、`app_min_supported_build=3`及iOS五键保持；文件与DB不是跨域事务，分别确认与恢复。
- 回退：以本次宿主机0700前态备份及原immutable文件为准。文件门禁失败仅恢复本任务写入且未再漂移的文件；DB结果不明时先读回完整现值/trace审计，不盲目重放或覆盖后续发布。Android latest别名与设置分开记录恢复；不删除原包、历史审计或扩展表。
- 当次Android/iOS最低支持build均3，Android bridge URL按本次前态保持；Android已仅version/build/notes三键切换，说明为本记录恢复入口的NEW_NOTES，不声称红屏已修复或全部卡顿消失。iOS五键、35running容器与schema0095按本次前态保持。内部真实route.endpoint/SettingService投影与公开HTTP401/HEAD是服务端证据，不等于真实用户鉴权HTTP或设备弹窗/覆盖升级验收。
- 源静态回填/索引/WIP：各自页面两Android字段、registry六身份与对应fixtures已受控回填，原不同UI保持；10份逆变换与原1373保全证明通过；两区索引前插已完成。最终有序review及分支提交已完成，不merge/push main。
- 运行中命令/CI/自建隧道：公开执行、后验和源专项均已exit0；ssh PID32776/loopback18947于20:44:28关闭、listener0，exec session45565的-1是有意终止。无仍运行的本任务上传、测试、构建、CI或自建隧道；归档与证据分支提交已完成，文档代理无发布命令或隧道。
- 恢复先读本记录的新授权，核对当前发布阶段、actual文件SHA、当次live设置/审计/静态前后状态及备份，再选择可恢复下一步。没有main合并/推送或iOS发布授权。

## 最终收尾回执

2026-10-07T20:56:41.847538+08:00：R1–R6发布交付完成。最终SPEC20:53:36.116→QUALITY20:53:36.143+08接受；源码及初始台账提交`eda262aea4354aab1e218ac7493af57c1b5fde61`（codex/android-2204-release），main未merge/push。详见[提交回执](../../verification/artifacts/2026-10-07/android-2204-release/commit-receipt.json)和[最终审查](../../verification/artifacts/2026-10-07/android-2204-release/preflight-review/closeout-acceptance-metadata.json)。本段只闭合发布记录；真机弹窗/覆盖与红屏修复仍按上述独立缺口继续。
