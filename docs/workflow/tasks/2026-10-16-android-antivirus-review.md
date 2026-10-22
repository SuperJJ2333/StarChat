# Android 安装报毒与覆盖升级评估

## 恢复入口

- 目标：核查 `a.gray.BulimiaTGen.f` 安装告警，评估处理方式并保留正式用户覆盖升级能力。
- 用户直接反馈：Redmi K80、HyperOS 3.0.308、小米安全管家、安装时出现；“任何畅聊版本”为用户描述，尚未逐版实测。Android API、管家版本与引擎/病毒库仍未知。
- 当前状态：用户已确认官方测试包2217仍在K80出现同名安装告警，AV-06未通过。腾讯官方MD5库对2216命中同名中风险，对2217返回未知；根因未定位。独立隐私初始化修复及既有构建验证保持有效，不能当作报毒已消除。
- 授权边界：用户于本轮回复“好的，请你开始推进”，承接已说明的调查、确认问题修复、稳定签名和覆盖升级计划。没有变更正式分发/更新弹窗，没有向外部检测平台上传 APK 或发送申诉。
- 负责人：主代理；工作树 `C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat`，分支 `codex/android-consent-20261016`，修复提交 `746f1712daebbd31df0c1d679564dde1238a0375`。所有权见下面计划；保留工作树既有无关文档。
- 关联流程：[移动交付](../../runbooks/mobile-delivery-workflow.md)、[固定 APK 打包与签名](../../runbooks/android-apk-rebuild.md)；[本轮实施计划](../../superpowers/plans/2026-10-16-android-antivirus-privacy.md)。
- 最后阶段更新：2026-10-16 13:22+08:00；[2217继续调查](../../verification/2026-10-16-android2217-antivirus-followup.md)。
- 下一步：用户明确选择“暂不外发，保留复核材料”。本地保留2217复核包及原始证据，不发送邮件、不提交申诉或上传APK，也不再等待本次外发确认。告警仍未解决；缺真实设备文件SHA、管家/病毒库、具体规则及保数据升级结果。仅在用户后续明确授权对外提交时恢复该步骤，无需重做相同输入构建/测试。

## 验收台账

| ID | 场景及预期 | 当前证据 | 状态及缺口 |
| --- | --- | --- | --- |
| AV-01 | 明确告警来源及样本 | 用户确认 K80/HyperOS 3.0.308/小米安全管家/安装阶段，官方测试包2217且详情只有名称 | 缺 Android/API、管家版本、病毒库及手机文件哈希；腾讯2216同名结果不等于手机引擎已确认 |
| AV-02 | 正式签名连续 | 2215、2216、2217 均为同一 75b31 证书，v2/v3 验证通过 | 旧包复用原构建证据；2217本轮重新验证；不等于真机保数据升级通过 |
| AV-03 | 正式包身份正确 | 本轮重新计算本地 2216 final.apk SHA256，与构建收据一致 | PASS；不是 Redmi 反病毒检测通过 |
| AV-04 | 检查当前更新链路 | 源码显示用户点击触发、签名描述校验、基线/补丁/目标哈希、目标包名/证书/版本检查、系统安装确认 | 静态核查；未据此宣称不存在其他风险 |
| AV-05 | 实际旧包保数据升级 | 需分别从正式 2215、2216 升至2217候选，检查 UID、firstInstallTime、登录、本地聊天、解密、媒体、推送、通话 | 候选已就绪，待真实 K80；Debug 不同包名模拟器不能替代 |
| AV-06 | 告警闭环 | 用户明确反馈2217仍出现a.gray.BulimiaTGen.f；腾讯2216原始MD5结果同名中风险、2217未知 | FAIL_USER_REPORT；尚未取得厂商命中依据，不宣称误报、已消除或所有环境通过 |
| AV-07 | 应用主动初始化须检查持久化同意 | 原生实际 Application + SharedPreferences；仅替换外部 SDK 副作用 | RED 3项/2预期失败；GREEN 7 PASS；完整原生101 PASS/1可选夹具SKIP；独立SPEC→QUALITY PASS |
| AV-08 | 样本权限与SDK来源清单 | 原正式2216：44去重权限、38组件、7显式导出、14个.so、4个推送关联SDK哈希 | 库来源匹配不是无病毒证明；已生成待提交复核包 |

## 版本与证据

- 当前已发布 Android：0.4.47+2216，`com.liuhetong.mobile`，ARM64。
- 本地正式 APK：`C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/docs/verification/artifacts/2026-10-16/android2216-release/arm64-final/final.apk`。
- 2216 APK SHA256：`db914f66229cffa79825954200845ac841fd10486c77fb8ecce94dbef7b41039`；73,262,170 字节。
- 固定证书 SHA256：`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。
- [2216 签名日志](C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/docs/verification/artifacts/2026-10-16/android2216-release/arm64-final/signature.log)、[构建收据](C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/docs/verification/artifacts/2026-10-16/android2216-release/arm64-final/receipt.json)、[2215 签名日志](C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/docs/verification/artifacts/2026-10-12/android2215-release-candidate/run-20261012-132000/apksigner-verify.log)。
- 已发布包来源仍见 [2216 发布任务](2026-10-16-android2216-release.md)，不包含本轮后续修复。候选源码为 746f1712；Android 构建命令单独指定 0.4.48+2217，共享 pubspec 仍为 0.4.47+2216，不改 iOS 已有交付。
- 本地候选：`C:/Users/Administrator/Downloads/ChatFlow-0.4.48-build2217-arm64-candidate.apk`；SHA256 `385663ac9d6cfb9befc726151c69883ee540fafd705f5cb9037ec85df1d0d8ac`；73,262,170字节；12:59+08已单独发布官方测试入口，正式2216及弹窗保持，见[分发任务](2026-10-16-android2217-candidate-download.md)。
- [本轮报告](../../verification/2026-10-16-android-antivirus-review.md)包含验证范围与下一步真机清单；构建证据在本任务 artifacts 下 `arm64-candidate-2217/receipt.json`、`steps.tsv`、`rebuild-verification.log`、`candidate-continuity.json`。

## 已确认事实与假设边界

1. 当前 release 的 R8 和资源收缩关闭；交付流程为源码编译、常规重建、对齐及固定签名，没有新增加壳或代码加密。
2. 当前正式清单包含 `REQUEST_INSTALL_PACKAGES`、全屏来电、精确闹钟、电池优化豁免、悬浮窗等声明。权限声明不等于获授，也不能直接认定为报毒原因。
3. 当前 Gradle 固定引入 Getui gtsdk 3.3.15.0、gtc 3.3.3.0、gsido 1.4.14.0。需要审计其实际用途、合并组件和 SDK 来源，不能仅凭 SDK 名称认定恶意或擅自移除推送。
4. 历史 2026-09-02 报告针对 0.3.26+29，其“没有安装权限、仅浏览器更新、无推送 SDK”等描述不能代表当前 2216；报告对该告警名称和触发原因的解释没有当前厂商确认，不作为定论。
5. 当前增量更新代码要求目标证书与已安装证书相同，校验签名描述及完整性后交由系统安装器处理。任意换签会同时影响系统覆盖升级和现有增量更新信任逻辑。
6. 更早的 `b4784ac3…` 证书与当前 `75b31c66…` 不同。不能把最近正式版本的签名一致性推广为“所有历史版本都能覆盖”；不得自动卸载、清数据或降低校验。

关键代码：[更新按钮](C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/apps/mobile_flutter/lib/features/update/app_update_dialog.dart:60)、[增量校验与安装](C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/update/AndroidDeltaUpdate.kt:86)、[证书一致性规则](C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/update/DeltaTrust.kt:18)、[正式合并清单](C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/docs/verification/artifacts/2026-10-16/android2216-release/arm64-final/decoded/AndroidManifest.xml:4)。

## 推荐路径与优先级

- P1：先固定告警样本与检测环境，检查签名及来源，获得厂商检测依据；检查权限实际需要、SDK 初始化时机/数据收集和依赖来源。只修正有证据的问题，保留必要的推送、来电和消息能力。
- P1：沿用相同包名、原证书和密钥，递增 versionCode。未来候选与旧正式包进行真实保数据覆盖升级，检测与功能验证均通过再灰度。
- P1：若核实属于误报，准备包名、版本、APK SHA256、证书指纹、下载来源、复现过程和审计说明，走小米官方技术支持复核；具体检测合作方以风险详情/厂商回复为准。本轮未提交。
- P2：若产品决定采用浏览器或应用商店全量更新，可单独评估删除不再使用的应用内安装能力及安装权限。这是功能简化方案，需评估流量/体验损失，不能承诺消除告警，不能因为一个标签直接删除功能。
- 不推荐：为改变检测结果而随机换证书、增加填充或对代码加壳加密。保持原证书重新签名可以保持签名连续性，但不保证解除告警。TLS/E2EE/本地数据保护应继续保留，与安装扫描是不同问题。
- 密钥轮换仅适合有明确安全或密钥治理理由的独立工程：需要签名沿革、系统兼容和现有增量升级策略评估；不是普通重签，也没有消除告警的保证。

官方依据：[Android 应用签名与升级](https://developer.android.com/studio/publish/app-signing)、[Android v3.1 签名轮换兼容规则](https://source.android.com/docs/security/features/apksigning/v3-1)。前者明确普通覆盖升级核验证书；后者描述 Android 13+ 的轮换与旧系统签名兼容，不能简化成任意新证书直接覆盖。

## 阶段计时与验证范围

| 阶段 | 开始 | 结束 | 类型 | 结果 |
| --- | --- | --- | --- | --- |
| 用户反馈、历史资料、官方文档及代码调查 | 本轮开始时间未单独采集 | 2026-10-16 12:03:00+08:00 | 主动/工具 | 确认签名约束和历史报告失效范围；根因未定 |
| 本地包哈希核对及日志复用 | 本轮末次命令 | 2026-10-16 12:03:00+08:00 | 工具 | Get-FileHash SHA256 与收据一致，末次 pwsh 退出 0、工具耗时 4.76 秒；不是整轮耗时 |

- 工具：Windows / PowerShell 7，UTF-8；官方网页查询使用现有 web 工具（AgentKey 能力未暴露，未额外安装）。
- 首轮仅调查；以下为用户批准继续后新增的源码修复和验证，不能把首轮未修改状态沿用为当前事实。没有 Redmi 检测通过证据。
- 前期定位两个不存在的 update 目录后，已通过文件清单定位至 `lib/features/update`；此查询失败不属于产品失败。
- 总墙钟开始时间未知，不估算；没有后台进程、CI、隧道或待结束扫描任务。

## 回退与下一步

- 本轮新增原生初始化门禁修复，正式包、签名身份、服务和更新弹窗未改动，无生产回退操作。
- 后续若候选失败，停止扩大分发并回退更新元数据；已升级用户通常应通过原签名、更高 versionCode 的修复包恢复，不能假设旧 APK 可无损降级。
- 首先补齐 K80 风险详情和检测环境，核对下载 APK 与本记录哈希；随后结合厂商依据选择修复或误报复核，保数据升级仍作为发布硬门禁。

## 2026-10-16 继续执行：独立缺陷与已完成验证

已确认的独立缺陷：Application 在未持久化同意时调用 Getui preInit。现行厂商集成指南要求 preInit 和 initialize 都在同意后调用。未发现证据证明这个时序缺陷导致安装期的病毒标签，二者不得合并为一个根因结论。

修复：原生 GetuiConsent 读取原 FlutterSharedPreferences 文件中的 flutter.privacy.agreement_accepted.v1，缺失、false、损坏及读取异常均拒绝本入口初始化；Application 和 MethodChannel 共用门禁，同意后先 preInit 再 initialize，保留原密钥/包名/SDK/权限。

范围限制：AppHome 原有“已登录旧用户补写同意”仍会把 accepted()==false 补写为 true。它是本次审查指出的独立遗留 P2，包含明确 false 或读取异常的混淆；本轮没有改登录/迁移策略。因此只能声称原生调用入口按当前持久化状态拒绝，不能声称整个应用始终尊重撤回/损坏状态。后续需区分旧版本缺键与明确拒绝/读取失败，并验证旧同意依据；原生SDK provider/独立进程联网仍需运行时验证。

证据目录：`C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/docs/verification/artifacts/2026-10-16/android-antivirus-review/`。

- 12:07:48+08 恢复只读核查，实际仅 emulator-5556/API28，非 Redmi 真机。
- 前置环境首次 Gradle 失败：已生成插件路径引用 W:，恢复本任务短盘符映射后解决；另修正测试框架已移除的 buildApplication API。两次非产品红灯日志分别保留，均不当作缺陷复现。
- RED：12:18:02.357+08，实际 Application 测试3项中2项预期失败（同意前仍调用 preInit），日志与 consent-red.xml。
- GREEN：12:20:10.426+08，7项通过；单次 Gradle 37秒，JUnit用例3.73秒，两者不是同一计时口径。
- 完整 Android 原生回归：Gradle退出0，54秒；14套件共102项，101 PASS/1 SKIP/0 FAIL/0 ERROR；跳过项要求显式指定已签APK夹具，未冒充真机安装或互通通过。
- Python 隐私、APK结构、增量更新专项：退出0，16 PASS，177.12秒，python-security.xml/log；包含仓库秘密字面量检查，无外发秘密。
- 仓库/部署策略各退出0。verify.ps1 前置 .env 缺失，完整脚本未运行，没有借用生产配置。Dart仅注释变化，按影响范围复用既有共享逻辑验证，原生改动单独完整回归。
- SPEC 后 QUALITY 独立只读审查通过；保留旧同意迁移、SDK运行时、K80与正式覆盖升级缺口。
- 2216 .so 追溯：libzxprotect.so 与 com.zxid.sdk:sdk-prod-channel-getui:3.3.7.58976 AAR 内 ARM64 文件 SHA 完全一致。不能由名字判恶意，也不能由来源一致判安全。3个Getui导出组件无组件级permission，需要结合SDK实现/厂商说明评估，未认定为可利用漏洞。
- 已生成 Xiaomi-review-ChatFlow-2216.zip，包含5份可共享复核资料，仅使用公开包身份与技术清单，无用户账号、消息或签名私钥；尚未提交。
- 12:31:15.158–12:41:19.719+08：2217 ARM64候选固定流程构建完成，总604.56秒；其中Flutter源码构建227.1秒。20项步骤全部退出0，外层控制器退出0。完整比较25,415个类/168,869个方法，重建前后smali语义、清单语义和274个native/asset条目一致。
- 12:42+08：2217新签名v2/v3通过；与2215/2216证书一致、包名一致且versionCode递增；相对2216权限和组件属性一致，14个native库哈希未变。静态比较不替代保数据覆盖升级或检测通过。
- 本轮未安装新APK至模拟器；仅有API28 x86_64模拟器，不能替代ARM64 K80。构建临时W:映射已清理。没有新建服务器隧道或生产发布任务。

## 13:16+08 2217继续告警的证据跟进

用户确认触发告警的是刚从官方测试入口下载的2217，详情只有名称。AV-06改为用户报告失败；实际保数据升级结果仍未知。先前隐私修复是独立缺陷，不是此告警已解决的证据。

腾讯官网公开MD5查询：2217 `4ed605bd76b316244928a8bdddb6cf16` 返回 warningLevel=4/未知；2216 `9fa683957fe13a194956351ec7db5e81` 返回 warningLevel=1/中风险及 `a.gray.BulimiaTGen.f`。两个样本均只查文件指纹，无APK上传。腾讯库有同名记录，但尚不确定K80实际引擎和具体风险代码。

本轮完整核对2217两份成品SHA，重新提取最终清单/原生库，整理9份资料的复核包并校验ZIP及Downloads副本。SDK反射引用仅静态核查；REA缺JADX前置未产出分析，浏览器不可用后按公开官网脚本的实际查询接口取数。未修改源码/服务/下载/更新弹窗，未产生2218。

13:19:21+08复核包完成；路径 `C:/Users/Administrator/Downloads/ChatFlow-2217-install-risk-review.zip`，SHA256 `543517df152727c56ec0348e7d6e9b1222344c4a26c09d85bb9dd982c5685394`。原始查询和生成收据位于 `docs/verification/artifacts/2026-10-16/android2217-antivirus-followup/`。已请求向小米官方邮箱外发上述资料的明确授权，尚未发送；官方渠道和剩余缺口见[跟进报告](../../verification/2026-10-16-android2217-antivirus-followup.md)。
