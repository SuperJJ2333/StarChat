# 2203 图标、历史跳转与服务器性能：2204模拟器已安装，手机候选已验包

2026-10-07：移动修复源码为 `3a620495ae048d3e4141f099e1926ecedc8669cd`，候选 **0.4.35+2204** 已按标准流程重建、独立审查并保留数据安装到 emulator-5556。完整 Flutter **5501 PASS / 9 skip / 0 FAIL**，analyze 无问题，移动 Python **354 PASS / 1 skip**。模拟器安装与ARM64本地候选技术验收已完成；正式 Android 仍为 0.4.33+2202，新手机候选未正式发布、未真机安装，尚无用户弱网复测结论。

## 四项反馈的根因与处理

| 用户反馈 | 已确认的原因 | 已实施与证据 | 尚需验证 |
| --- | --- | --- | --- |
| 2203 emoji、图形 icon 缺失 | 实际安装包与源 APK 都仅剩三个 Flutter snapshot 项，缺少 AssetManifest、FontManifest、字体和 emoji。Flutter 3.44.9 的旧输出缓存对同一物理 C:/S: 路径按不同字符串执行清理，删除319个新生成资源；仅检查源包与最终包相等未识别两者同时残缺 | 使用本任务新缓存和单一 U: 构建路径；对源/最终 APK 独立检查完整资源、字体引用、全部变体及源字节。实际新包含310项声明资源、56个emoji、225个SVG、Material/Cupertino两套字体；实际旧2203包仍能触发门禁失败 | 实际各页面字形显示反馈；启动零资源错误不等于逐图标视觉验收 |
| 弱网历史插入前几天消息 | 真实 SDK 延迟历史请求跨越 limited sync 片段替换，旧响应把旧历史接到新头并覆盖分页 token，原可见 anchor 丢失；曾复现 day30→18→17 | 片段代次约束 HTTP/数据库/成员加载等 await 边界；阅读窗口独立于 live 片段，按缓存事件 ID 连续读取，必要时用真实 context 获得合法 token；保留撤回与权限边界 | 新包真机弱网同场景复测 |
| 快速上滑跳到十几天前 | 片段混合导致可见锚点退出列表，列表退回新片段起点；缓存末端 token 也可能跳过尚未加载的缓存行 | 覆盖真实变量高度列表、context 在途/limited sync/分页/窗口切换、反向拖动和真实传输；54项历史专项，加26项离线列表测试共80项通过 | 真机快速连续上滑与原账号长历史复测 |
| 明显卡顿 | 未授权 xmrig 占用约4个CPU核心与2.29GiB内存，造成实际服务器资源压力；客户端原有同步计时把历史/本地回声进度当作 HTTP 响应，误把长轮询残余记成约30秒 processing | xmrig 已停用并保留受限取证，CPU与内存明显恢复；修正两个计时消费入口和 watchdog，真实处理中的进度继续维护心跳，82项专项通过 | 不能据此断言所有卡顿消失；现有本地加载/慢帧数据仍需真机阶段及帧分析 |

## 服务器处置与日志结论

用户明确确认未部署 xmrig，并单独批准只禁止 root 密码登录。15:03:53+08 已停止、禁用挖矿服务。CPU采样由61–70%下降到6–13%，15:18复查3–5%；17:55:19复查 **3.78%**，可用内存 **4010.5 MiB**；18:51:04最后只读采样 **6.97%**、可用内存 **4006.9 MiB**，服务 inactive/disabled、MainPID=0，无同名挖矿进程。业务与 Matrix 七容器身份、启动时间及重启计数保持。

原件仅保存于服务器 root-only 取证目录 `/opt/starchat/incident-evidence/20261007-xmrig`。挖矿启动前约20秒出现成功 root 密码登录，这是入口线索；尚未证明完整入侵路径或主机已彻底清除所有驻留。

SSH root 公钥登录策略于16:32:02.952+08 **APPLIED_AND_INDEPENDENTLY_VERIFIED**：`PermitRootLogin prohibit-password`，独立新公钥连接 exit0，保留23421端口、跳板、公钥与其他用户策略。第一次确认连接超时曾安全回退；只以最终21/22号证据作为成功回执。

用户“最近一个小时”按回复时点检索14:04–15:04+08。该时段 `/messages` 共3950项、全200，p95 **68ms**、最大205ms；已保留同步请求无429/5xx。约30秒长轮询是等待时间，旧客户端约30秒 processing 尾部又受假进度计时污染，均不能直接当作CPU或解密耗时。连续系统监控与历史慢SQL/锁等待记录不足，当前零锁等待不证明过去无瓶颈。详情见[服务器报告](artifacts/2026-10-07/history-icons-performance/server-performance/diagnosis.md)和[最后只读采样](artifacts/2026-10-07/history-icons-performance/root/server-closeout-readonly.json)。

## 源码、验证及失败闭环

源码保留在 managed worktree `C:/Users/Administrator/.codex/worktrees/history-icons-performance-2204/StarChat`、分支 `codex/history-icons-performance-2204`。**未合并或推送 main**；主区1373项既有 tracked WIP按原始文件SHA保全，本任务只增加自己的文档/证据和恢复索引条目。

| 门禁 | 最终结果 | 证据与边界 |
| --- | --- | --- |
| 资源专项 | 22+5 PASS；实际旧2203 source/final拒绝 | [资源规格](artifacts/2026-10-07/history-icons-performance/final-source-review/resource-spec.md)、[质量](artifacts/2026-10-07/history-icons-performance/final-source-review/resource-quality.md) |
| 历史及真实列表 | 54+26 PASS | [历史结论](artifacts/2026-10-07/history-icons-performance/history-scroll/findings.md)、[增量规格](artifacts/2026-10-07/history-icons-performance/final-source-review/incremental-spec.md)、[增量质量](artifacts/2026-10-07/history-icons-performance/final-source-review/incremental-quality.md) |
| 同步计时与 watchdog | 82 PASS | [结论](artifacts/2026-10-07/history-icons-performance/client-lag-trace/findings.md)、[审查](artifacts/2026-10-07/history-icons-performance/telemetry-review/review.md) |
| Flutter analyze | exit0，无问题 | [metadata](artifacts/2026-10-07/history-icons-performance/root/analyze-frozen-final-metadata.json) |
| Flutter全量 | 5501 PASS / 9 skip / 0 FAIL，exit0 | [日志](artifacts/2026-10-07/history-icons-performance/root/flutter-full-frozen-final.log)、[命令与时间](artifacts/2026-10-07/history-icons-performance/root/flutter-full-frozen-final-metadata.json) |
| 移动Python | 354 PASS / 1 skip，exit0 | [日志](artifacts/2026-10-07/history-icons-performance/root/mobile-python-final-green.log)、[命令与时间](artifacts/2026-10-07/history-icons-performance/root/mobile-python-final-green-metadata.json) |
| Android原生 | 59 PASS，输入不变复用 | [复用依据](artifacts/2026-10-07/history-icons-performance/root/native-evidence-reuse.json)；原生tree/相关文件hash匹配 |
| scripts/verify.ps1 | NOT_EXECUTED | [预检](artifacts/2026-10-07/history-icons-performance/root/verify-preflight.json)：本地 .env/local.env 缺失；未导入生产秘密 |
| 新iOS编译/IPA | NOT_EXECUTED | 本轮为Android模拟器候选；原生iOS输入不变，不把旧iOS验收写成本候选通过 |
| 独立源码审查 | SPEC → QUALITY/SECURITY ACCEPT | [规格](artifacts/2026-10-07/history-icons-performance/final-source-review/mobile-spec-final.md)、[质量](artifacts/2026-10-07/history-icons-performance/final-source-review/mobile-quality-final.md)，增量随后有序接受 |
| 实际 APK 审查 | SPEC → QUALITY/SECURITY ACCEPT | [实际包规格](artifacts/2026-10-07/history-icons-performance/artifact-review/spec-acceptance.md)、[实际包质量](artifacts/2026-10-07/history-icons-performance/artifact-review/quality-acceptance.md) |

失败日志均保留：首轮移动Python353 PASS/1skip/1fail，未变源码与HEAD静态fixture隔离复现同样IndexError，仅调整旧fixture的摄像头条件查找；首次Flutter全量5473 PASS/9skip/28fail，27项为干净工作树缺旧测试所需证据父目录，另1项反向滑动fixture因真正 forkHistory 不再走Fake覆盖方法。建立所需测试目录，fixture改为真实SDK传输并等待真实异步回调，保留原拖动/窗口/锚点断言；未更改生产鉴权。最终全量再次执行通过。首次analyze一条super_parameters提示已最小修正并重跑。旧CI缺libolm/历史fixture和基础设施权限失败未借作PASS。

## 模拟器APK与实际安装

[模拟器专用 x86_64 debug APK](artifacts/2026-10-07/history-icons-performance/delivery/ChatFlow-0.4.35-2204-x86_64-debug-rebuilt.apk)，135803107 bytes。

- source commit：`3a620495ae048d3e4141f099e1926ecedc8669cd`。
- 1881项移动输入冻结manifest SHA：`76d10524056a5efe9da34f679bd3b69de046859d9f67a372a0f13883b9f8d840`。
- pubspec.lock SHA：`ac0966cb75f61763073bfc48ef5e8b93b85cf6cf46ebaa921d8b3739c62694ac`。
- source APK SHA：`ad9502dbdb3c3e007249a96e8a39c55c14cda34b4435884d5d40d24222c37222`。
- final/实际安装 APK SHA：`221aca2d4ea486673b650b0a7ca4d580f9c2655c7337bd74bd8e93de6a353b5c`。
- 稳定签名SHA：`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，单签v2/v3、对齐通过。
- 工具：Windows/pwsh7、Flutter3.44.9/Dart3.12.2、Apktool2.12.1/build-tools36；新缓存、唯一U路径、锁未变。
- 源构建 → 常规DEX/资源/manifest重建 → 对齐 → 稳定签名 → 完整资源/语义/原生锁屏门禁 → 独立最终重解包，各步骤exit0，338项原生/资产保全。
- 18:36:10–18:36:46+08 `adb install -r` 覆盖成功，未卸载/清数据。UID10090、首次安装2026-09-26 04:06:20保留；读回base.apk SHA相同。[安装回执](artifacts/2026-10-07/history-icons-performance/root/device-install-receipt.json)。
- 18:38:55+08 同PID8170运行129.141秒，匹配Java fatal/native fatal/资源缺失/字体加载失败/Flutter未捕获异常均0。仅保留聚合计数，无原始聊天日志。[启动检查](artifacts/2026-10-07/history-icons-performance/root/device-startup-smoke.json)。


## ARM64手机候选

[手机 ARM64 release APK](artifacts/2026-10-07/history-icons-performance/delivery/ChatFlow-0.4.35-2204-arm64-release-rebuilt.apk)已准备，可供原账号真机覆盖升级复测；不是线上正式更新发布。

- com.liuhetong.mobile，0.4.35+2204，standard ARM64 AOT release，82848798 bytes。
- 最终SHA：`a2d100be2e0273107d231dfd82fee316c89d3c1cb37ff976ba36d8f2fcf835e5`；source SHA：`2a3f885c86a19e3d7d4b646aad344a3d2c51afd9ae2691e80935d28ad5301d49`。
- 同一源码3a620495、1881输入manifest76d10524…、lock ac0966cb…；稳定75b31单签v2/v3、P16对齐。保留完整Material/Cupertino字体，无图标字体裁剪、Dart混淆或R8资源/代码收缩。
- 实际ARM64 ELF/AOT、无kernel/debug snapshot、不可debuggable、310项声明资源/319个Flutter成员、字体源SHA/SFNT/cmap、338原生资产保全、独立解包语义/锁屏/冻结全部通过。[构建身份](artifacts/2026-10-07/history-icons-performance/android-arm64/run-20261007-185625/artifact.json)。
- 新run18:56:25.638–18:59:01.703+08，约156秒，所有步骤exit0。19:03:49独立 [SPEC](artifacts/2026-10-07/history-icons-performance/artifact-review/arm64-spec-acceptance.md) → [QUALITY/SECURITY](artifacts/2026-10-07/history-icons-performance/artifact-review/arm64-quality-acceptance.md) ACCEPT；11项fresh工具检查及native-lock均exit0。[接受身份](artifacts/2026-10-07/history-icons-performance/artifact-review/arm64-acceptance-metadata.json)。
- 未执行真机安装、视觉/弱网/性能验收或正式发布。18:48:29只读正式版本仍Android2202/iOS2194；[版本记录](artifacts/2026-10-07/history-icons-performance/root/live-build-arm64-preflight.json)。

ARM64首轮18:49:12–18:51:33 exit1，生成Java仍引用dev integration_test，发布classpath将其排除；旧辅助脚本硬编码S路径导致修正未触及U候选。root漏查了该路径；误改的旧工作树ignored生成文件已按已知唯一block字节等式恢复9046字节/SHA6c171828…ce3da，[恢复证据](artifacts/2026-10-07/history-icons-performance/android-arm64/old-registrant-restoration.json)。实际本地SDK `--no-pub` 跳过平台注册更新，旧helper“assemble二次生成”的注释不适用于本轮代码。新本任务helper将目标绑定候选repo/mobile、要求ignored/untracked，仅删唯一274-byte已知dev注册，拒绝未知/重复/越界内容，构建后核对其余字节和精确SHA；5项正负例、独立审查及实际成功构建通过，源码/锁/SDK未修改。见[依据与门禁](artifacts/2026-10-07/history-icons-performance/android-arm64/bounded-helper-findings.md)、[独立边界复核](artifacts/2026-10-07/history-icons-performance/artifact-review/arm64-driver-correction-review.md)。首轮失败完整保留，不计作通过。

## 时间与下一步

首个精确任务基线14:55:56+08；更早工作时间未知。服务器止损15:03:53，SSH最终确认16:32:02；移动Python最终17:42:58–17:43:34，analyze18:17:22–18:17:36，Flutter全量18:17:36–18:22:14；APK构建18:28:01–18:32:46约285秒，包审查18:35:34，安装18:36:10–18:36:46，启动检查18:38:55。各并行调查区间不能累加为总工时；首基线至启动检查墙钟约3小时43分。

下一步用已验收ARM64候选覆盖安装到原手机，复测emoji/图标、弱网连续上滑、快速滑动及卡顿。模拟器2204也可复测。ARM64构建与发行技术门禁已完成，正式更新发布按当次明确授权处理。新候选的真机帧/阶段证据仍须核对，不能沿用旧2202污染的processing值。源码分支与worktree保留；没有运行中的CI、构建或本任务隧道。两次ARM64构建与修正区间已记录；首基线至ARM64现物接受墙钟约4小时8分，不累加并行工时。

[任务记录](../workflow/tasks/2026-10-07-history-icons-performance.md) · [计划](../superpowers/plans/2026-10-07-history-icons-performance.md)
