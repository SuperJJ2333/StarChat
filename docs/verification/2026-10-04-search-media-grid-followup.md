# 搜索旧媒体网格后续修复：2200设备反馈通过

用户确认模拟器2199仍不能显示历史媒体缩略图，点击也无法打开。实际安装APK SHA256与2199成品完全一致，排除未安装；原SDK/API测试与安装smoke没有覆盖实际RoomPage搜索入口。根因为窗口外搜索结果仍先经过live `findMessage` 判断，图片查看器另有限制选中项必须属于当前图库。

本轮沿[批准计划](../superpowers/plans/2026-10-04-search-media-grid-followup.md)补齐页面公共单事件读取，不扩大聊天时间线，不变更SDK、密钥加载、原生存储或依赖锁。任务状态见[独立记录](../workflow/tasks/2026-10-04-search-media-grid-followup.md)。0.4.31+2200已在22:15以install-r安装模拟器，用户已确认旧媒体缩略图和点击正常；没有正式移动发布。

## 第一候选证据

源码5ba5dd63、版本及workflow1a3b84c4。有效RED有当天图片实际1x1解码和图库打开对照，旧图片/视频独立失败；当前图片邻居浏览回归另外捕获并修复。最终覆盖43PASS；较早202PASS专项先于图库邻居修复，明确保留顺序。页面使用真实SDK搜索库接口、合成SDK/HTTP和真实文件缓存；视频仅证明查看器路由，不宣称原生播放或真实账号验收。

第一候选root全量5432PASS/9skip/0fail，21:09:06–21:13:12+08；冻结版analyze0，21:14:34–21:15:01+08。规格/domain独立接受；质量/security发现Q1 P2离屏排队读取不能撤销，暂停打包进入修复。上述全量与1870文件manifest bcd3946d…均是第一候选证据，不能作为Q1修复后最终源的通过声明。

证据在[本轮公共证据目录](artifacts/2026-10-04/search-media-grid-followup/)，包含implementation-handoff.md、implementation-inputs.json、有序source-spec-review.md/source-quality-review.md及相应日志。早期缺接口、无效PNG和异步等待不足的诊断失败不算产品RED。`.env`/`local.env`缺失，整库verify预检后未执行；未引入生产秘密。

## 最终候选与平台验收

Q1 fix round1提交29236bd3：保持搜索打开并滚动的实际页面RED捕获离屏grid-74被读取；修复后16专项PASS、46受影响PASS、analyze0。root最终源全量5435PASS/9skip/0fail（21:42:52–21:47:02+08）；1870输入新manifest30a4dcde…另存绑定该commit，不覆写第一候选证据。

Q1有序delta规格与质量复审接受，无新增P0–P2。Android源码构建/Apktool2.12.1重建/zipalign36-P16/75b31固定签名和独立验包通过，实际包内新SearchMediaDemand及kernel SHA与source相同、与2199不同。成品135721187bytes，SHA035f3fb13333a221d940316df5005eb11767f14582f334e6612dc8e20f00cf84，标准x86_64 debug。22:15:30–22:15:46+08 install-r，UID10090/firstInstall2026-09-26 04:06:20保持，实际安装base.apk SHA相同；22:20观测同PID30008持续277.7秒/crash0，只是启动smoke。

iOS run37207572736完整生产编译SUCCESS，iOS18/26两个job在host测试FAIL：模拟器配置提前移除mobile_scanner，新增真实RoomPage测试间接引用扫码Dart包导致编译失败；未进入seed/verify连续性，不能声称新native双端通过。574ef30已修复workflow依赖顺序，不改变移动源码/锁/密钥/原生fixture；后续run37209352829实际macOS/native GREEN，独立最终证据复核已接受。原iOS连续性证据只在相关源码输入完全相同的边界内复用；不会把旧iOS CI或安装smoke当新页面验收。用户已确认2200真实账号缩略图/点击正常。新的日期/context问题转独立任务，不视为H1完成。


最终iOS修复run37209352829/574ef30全部三项SUCCESS，完整生产编译及18/26原生seed/new-process retained通过；见ios-repair-run-final.json与ios-repair-jobs-progress.json。新增日期/context跟进见[任务](../workflow/tasks/2026-10-04-search-date-context-followup.md)。

最终平台有序复核报告final-platform-review.md（SHA c91a61d26d8d52cc26ce087caff24eba58b14494c5959ca642142600025403ab）接受，无阻塞发现。该验收不覆盖新日期/context源码、正式移动发布、iPhone真机覆盖或物理视频播放。
