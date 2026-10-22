# Android 安装风险核查与 2217 本地候选

2026-10-16。结论：已修复独立的个推原生初始化时序问题，并完成固定签名候选；尚无证据确认 `a.gray.BulimiaTGen.f` 的根因、误报性质或已消除。用户报告环境为 Redmi K80 / HyperOS 3.0.308 / 小米安全管家 / 安装阶段；检测组件版本、引擎、病毒库和实际触发文件仍待核对。

## 交付身份

| 项目 | 值 |
| --- | --- |
| 本地候选 | [ChatFlow-0.4.48-build2217-arm64-candidate.apk](C:/Users/Administrator/Downloads/ChatFlow-0.4.48-build2217-arm64-candidate.apk) |
| 包名 / ABI | com.liuhetong.mobile / arm64-v8a |
| 版本 | 0.4.48 / 2217，Android命令行单独覆盖，共享pubspec与iOS版本未变 |
| SHA256 | 385663ac9d6cfb9befc726151c69883ee540fafd705f5cb9037ec85df1d0d8ac |
| 大小 | 73,262,170字节 |
| 证书SHA256 | 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff |
| 源码 | codex/android-consent-20261016 / 746f1712daebbd31df0c1d679564dde1238a0375 |
| 分发状态 | 仅本地候选；没有修改官网或更新弹窗。上次确认的公开版本仍为0.4.47+2216，本轮未重新访问生产。 |

2215、2216、2217证书一致、包名一致、版本递增，满足常规覆盖升级的静态身份条件；不能替代保数据安装验证，更早的不同证书版本不在这个结论内。沿用原用户测试过的密钥；没有换签规避、加壳或代码加密。

## 发现与改动

1. **P1，已修复原生入口：** Application 原先在读取用户同意前调用 Getui preInit。新增 GetuiConsent，使用现有 FlutterSharedPreferences 与隐私键；缺失、false、损坏或读取失败时本入口拒绝初始化。同意后按 preInit → initialize 顺序执行，Application 和 MethodChannel 共用门禁。[个推官方集成说明](https://docs.getui.com/getui/mobile/android/androidstudio/)要求初始化及注册在同意后执行。没有证据把此问题归因为安装告警。
2. **P1，待设备/厂商证据：** 已审计公开2216的44种去重权限、38个组件、7个显式导出组件与14个native库。候选权限/组件属性不变；所有14个native库与2216哈希相同。libzxprotect.so可追溯到固定卓信SDK AAR，来源一致并不证明检测通过。3个Getui导出组件缺组件级permission是后续审查面，尚无可利用漏洞证据。
3. **P2，单独遗留项：** Dart已有“已登录旧用户补写同意”会把缺键、明确false和读取异常统一处理；这次按批准范围保留旧登录迁移策略。因此本次是原生调用门禁修复，不能宣称应用的全部隐私流程已闭环。后续应区分状态、核验旧同意依据，避免覆盖明确拒绝。

## 已完成验证

| 验证 | 结果及范围 |
| --- | --- |
| 原生TDD | RED 3项中2项预期失败；修复后7项通过。实际Application与SharedPreferences，仅隔离外部SDK副作用。 |
| 完整Android原生回归 | 14套件102项，101通过 / 1可选签名夹具跳过 / 0失败 / 0错误，Gradle退出0。 |
| Python隐私/成品/增量专项 | 16通过，退出0，177.12秒。 |
| 仓库/部署策略 | 两项脚本均退出0。 |
| 独立审查 | SPEC → QUALITY通过；旧同意迁移及真机验证缺口保留。 |
| 源码构建与常规重建 | 20步骤全0；12:31:15–12:41:19+08，总604.56秒，源码构建227.1秒。 |
| 重建一致性 | 25,415个类、168,869个方法的规范化smali一致；清单语义、274个native/asset条目一致。 |
| 成品签名与版本 | 新成品apksigner v2/v3、对齐、ABI、资源检查通过；与2215/2216同证书；versionCode2217。 |

证据目录：[android-antivirus-review](C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/docs/verification/artifacts/2026-10-16/android-antivirus-review)。源码提交后冻结输入，构建前后输入清单一致；完整结果见 `arm64-candidate-2217/receipt.json`、`steps.tsv`、`rebuild-verification.log` 和 `candidate-continuity.json`。

范围限制：完整verify.ps1因缺本地.env未启动，没有借用生产配置。Dart仅注释变化，按输入影响范围复用既有共享逻辑证据。编译存在原有弃用/KGP提示，不称无警告。SDK真实联网、后台推送和真实覆盖升级未测；现有模拟器为API28 x86_64，本轮未安装此ARM64候选。既有libcrypto的16KiB/RELRO问题未由本修复解决。

## 下一步：Redmi K80验收

使用上述候选，保留旧App和数据进行系统覆盖安装；若系统仍提示风险，保留详情，不关闭安全检测或卸载清数据来绕过。首先确认当前已安装包签名属于75b31这一连续版本。

| 用例 | 通过标准 |
| --- | --- |
| 2215 / 2216 → 2217 | 系统认可覆盖更新；UID和首次安装时间不变；账号、本地聊天、解密与媒体保持。两条升级路径需分别验证。 |
| 同一K80安装检测 | 记录Android/API、管家/引擎/病毒库、时间、安装来源和完整详情；实际文件SHA与候选一致。不能以另一台模拟器结果代替。 |
| 首次安装、未同意/同意后 | 未同意无应用主动Getui初始化；同意后正常注册；同时观察SDK provider及独立进程行为，核查运行时联网。 |
| 已同意老用户 | 冷启动、锁屏、后台及恢复均不丢失原推送注册；消息/来电能力回归。到达统计需真实设备实测。 |
| 媒体/消息/更新 | 图片、视频、超级表情及失败重试正常；增量和全量更新完整性检查保持。 |

已生成[小米复核材料](C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/docs/verification/artifacts/2026-10-16/android-antivirus-review/Xiaomi-review-ChatFlow-2216.zip)：公开2216身份、权限、组件和SDK来源清单共5份文件，无私钥、账号或消息。本轮没有提交或联系厂商；需结合实际警告证据提交官方复核，不能把2217修改混写成2216已修复。

## 回滚及恢复入口

没有生产变更，无需服务器回滚。若候选回归，停止扩大分发；只撤销本次原生门禁修改并按固定流程生成更高versionCode修复包。已升级设备不假定可无损降级，不卸载或清数据。[任务记录](../workflow/tasks/2026-10-16-android-antivirus-review.md)保留授权、阶段计时、来源和下一步；构建临时W:映射已清理。
