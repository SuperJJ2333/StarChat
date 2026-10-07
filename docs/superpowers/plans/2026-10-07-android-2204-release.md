# Android 2204 正式发布与普通更新提示计划

**目标：** 发布现成受验`0.4.35+2204`正式ARM64 APK，通过既有App版本检查机制启用普通可跳过的更新提示，并证明下载、设置、路由及审计一致。

**授权：** 用户在获知debug会话红屏首因未确认/尚未修复后，明确要求“发布Android的最新版本，并且推送更新弹窗”。此授权覆盖本次Android发布与既有应用内更新提示；无需再问发布许可。不新增OS push或其他消息，没有iOS发布、main合并/推送或业务服务部署授权。

**成品身份：** source`3a620495ae048d3e4141f099e1926ecedc8669cd`，`com.liuhetong.mobile`、standard ARM64 AOT release、82848798bytes，SHA`a2d100be2e0273107d231dfd82fee316c89d3c1cb37ff976ba36d8f2fcf835e5`，固定signer`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。常规DEX/资源/manifest重建、P16对齐和实际APK有序双审已完成；本次原样发布此成品，不重建。

**依据：** [任务台账](../../workflow/tasks/2026-10-07-android-2204-release.md)、[生产工作流](../../runbooks/admin-production-workflow.md)、[分发职责](../../runbooks/app-release-deployment.md)、[轻量发布门禁](../../runbooks/release-metadata.md)、[Android固定打包](../../runbooks/android-apk-rebuild.md)、[移动证据复用](../../runbooks/mobile-delivery-workflow.md)、[前修复报告](../../verification/2026-10-07-history-icons-performance.md)。

## 所有权与边界

- root拥有当次生产快照、`release.json`、发布helper受控使用、上传/备份/切换、公网读回和恢复索引；lifecycle_record只写本新任务和本新计划两个文档，不改既有源码、索引、前任务、生产helper或服务。
- 本地新临时证据限主区`docs/verification/artifacts/2026-10-07/android-2204-release/`。保全主区原1373项WIP，root索引仅允许前插保留原字节，不从整个脏区构建/部署。
- 生产默认jump SSH/SCP：`ssh -J jumper -p 23421 root@207.56.8.8`；优先`scripts/starchat-server.ps1`，保留主机密钥和HTTPS验证。工作站公网验收按现有jumper loopback SOCKS，不改全局代理；完成后关闭自己创建的隧道。
- 更新弹窗是现有App检查响应的普通提示，事务CAS仅更Android`app_latest_version`/`app_latest_build`/`app_update_notes`三键；`app_apk_url`既有bridge、Android min3、iOS五键及强更策略保持。最终Android说明为“修复表情与图标加载；改善弱网历史记录连续性与快速上滑定位；优化同步状态统计。”；不声称红屏已修复或全部卡顿消失。
- 已知会话红屏根因仍未知、未修复。release断言不显示不是修复证据；更新说明和最终交付不得声称该问题已解决，手机覆盖/弱网/快滑/图标/卡顿复测另列。

## 1. R1：读取本次生产事实并冻结前态

- [x] 取得当次HK20:20:18.168815+08/SG20:20:21.268739+08安全前态；Android0.4.33+2202、iOS0.4.25+2194、两min3，schema0095_wallet_source_alerts、35running容器；ARM64 alias为2202，SG Deployed/ETagE1VC38T7YXB528/7旧路由。完整公共设置/hash/运行身份白名单与20:20:24–29两本地投影exit0在live-preflight记录，不保存原始含secret环境inspect。实际Android/旧无platform路由与发布后隔离仍在R4验证。
- [x] 本次HK目标2204文件不存在，当前设置/alias均2202，未发现2204目标占用；按这次前态准备，不用18:51或旧schema0094代替当前事实。后续发布前CAS仍须重新比较，不能把这次读回永久当不变状态。
- [x] 当次宿主机0700备份实际由21 publish建立：/opt/starchat/docs/verification/artifacts/2026-10-07/android-2204-202800，前态设置/静态与alias恢复边界已绑定；不以容器/tmp作为唯一备份。

## 2. R2：确认现成成品并复用不变证据

- [x] 20:21:22.2644279–20:21:24.4098075+08独立fresh-delivery-preflight PASS：精确82848798bytes/SHAa2d100be…fcf835e5、com.liuhetong.mobile、0.4.35+2204、nondebuggable/AOT arm64、唯一75b31 v2v3、P16检查exit0；旧实际双审证据身份匹配，无源码重建或公网回拉。
- [x] 以当次前态生成并冻结Android release JSON和CAS运行件；record SHA`44ae1e45ba6dbf0647601de6126ef46c2b3ce8528fc3e8be22bed1e7a6dad5db`，runtime SHA`dae5ec05d8a0b0a5ebb0d8d93a7e78b1dfa9b366ea6866010c856279e8e44211`，freeze manifest SHA`3a11022de11226a84d03f4d0e7a2f1707ce2c7e4fdeeeb2c28745cf54f6d97cf`。离线30PASS/exit0，真实隔离PG16.9六PASS/exit0；旧notes/CRLF返工只作历史，20:40有序SPEC→QUALITY已接受，冻结输入实际用于21发布，不重生成改变输入。
- [x] 受验成品已有source freeze、Flutter5501PASS/9skip、analyze0、Python354PASS/1skip及Android native59按输入不变复用；ARM64完整资源/ABI/签名/语义/P16与实际SPEC→QUALITY接受，详见前报告。
- [x] 本次复用输入相同的已完成移动源/实际包门禁，不新建源码包/重复全量或实际APK解包；本次内容预检完成，上传完整性和当次平台隔离仍须R3/R4完成。若需要改publisher行为，先明确所有权及真实失败测试，不从脏源码盲目扩围。

## 3. R3：不可变文件与分发入口先就绪

- [x] HK0700私有暂存20:26:16–17创建，5块顺序上传/逐块SHA和manifest至20:28:30全部exit0；20:29:51–53私有合并整包a2d100…精确exit0，随后16公共immutable安装已完成。未提前清理分块，未覆盖旧immutable APK。
- [x] 同runtime SHA传HK/SG，实际release/delivery CLI help各exit0；SG0700私有暂存已建，20:29:51–57当前cdn-precheck before/Deployed/新鲜ETag/策略保持exit0。私有准备不算新CDN路由上线。
- [x] 20:40:47–50公共immutable安装exit0，此时alias仍2202；20:40:56–20:41:13仅安装精确新HK-origin CDN路由，20:42:33–39 Deployed/HEAD/MIME/CORS检查exit0；20:42:47–50 ARM64 alias切2204，最后静态/settings前态检查20:42:58–20:43:01 exit0。
- [x] 20:43:24–30后验严格TLS direct/CDN/latest HEAD200/82848798/MIME、372byte registry/8354byte页面SHA一致；SG exact8routes/旧7保全/策略不变/Deployed。仅HEAD和小元数据，完整APK回拉0；未验证手机安装。

## 4. R4/R5：仅Android更新设置及弹窗投影

- [x] publication-acceptance-metadata绑定精确record44ae/runtime dae5；SPEC20:40:28.8920111+08接受后QUALITY20:40:28.9197325接受，前态CAS/事务/审计/未知结果及回退边界审查通过。
- [x] 20:43:09.357954–20:43:17.110974+08 publish exit0/PUBLISH_PASS，仅三键及匹配审计切换。Android bridge/min3与iOS五键保持；下载页/registry与设置分开验收。trace android2204-20261007-202800，宿主机0700备份/opt/starchat/docs/verification/artifacts/2026-10-07/android-2204-202800。
- [x] 后验真实运行route.endpoint+SettingService投影Android2204、iOS2194、旧无platform默认Android，exact3audits；公开HTTP三platform均401、HEAD通过。普通可跳过提示已配置，下一启动/前台检查按现有源码评估更新；这些不是实际用户鉴权HTTP请求，不证明设备已收到弹窗/覆盖安装，无新增OS push。
- [x] HK后验精确完整设置/iOS五键/min3/schema0095、5保留静态/其他ABI alias保持，所有35容器id/image/restart/start与当次前态完全相同；SG旧7routes/策略保持，新增唯一2204路由。共享下载页Android必要变化已验收，不声称整页字节不变；旧immutable保留支持回退。

## 5. R6：归档与可恢复交付

- [x] 当次record/freeze、执行01–21以及postflight HK/SG/route/HTTPS均已归档，公共发布PUBLISH_PASS及各check真实exit0、路由/exact3审计/隔离、公网及0700备份路径已绑定；没有将预审接受替代生产后验。
- [x] 各自不同UI页面仅两处Android字段、registry六身份与对应fixtures受控回填；primary Node57/managed Node54/managed Python32 GREEN，fixture版本RED4/3及旧warning基线同FAIL已留。source-audit证明10份before/inverse逐字节PASS；iOS页面未改，47冻结文件/22runtime entries保持。
- [x] root20:46:01两区索引各前插1434byte且原tail相同，primary1373原WIP只授权Android page两字段与current-state三前插delta，逆变换原hash准确，其他原字节保全。main仍be207，无merge/push。
- [ ] 最终后态有序review/证据复制与codex/android-2204-release分支提交待root回执；当前managed base3b77b00ef20422f173311c81c70263b6a0939b85，不能提前记本任务提交完成。
- [x] 本记录已分开报告实际APK源3a620495、成品已构建与Android已上线；手机不卸载覆盖/历史登录保留及弱网快滑反馈作为后续设备验收，红屏独立调查继续，不阻断已完成发布。仅本任务证据分支最终review/提交由root收尾。
- [ ] 若文件门禁失败，仅恢复本次写入且未再漂移的文件；DB结果不明先完整现值/trace审计读回，不盲目重放或覆盖后续版本。alias与DB分别确认恢复，保留旧包和历史审计。

最后更新：2026-10-07T20:47:19.832+08:00。Android0.4.35+2204已上线，R1–R5及普通提示配置/后验通过，R6源回填/索引/WIP保全完成，仅最终review/证据分支提交收尾；真机提示/覆盖和红屏根因修复未验收。root自建ssh PID32776/loopback18947已关闭，exec session45565的-1为有意终止。
