# Android 2222 缓存房间即时进入验证

状态：0.4.53（2222）普通 Debug 已于2026-10-17 23:45:47+08保数据安装至 emulator-5556，冷启动命中缓存、入房及历史滚动已观察。首次原生失败和首次冷启动缓存拒绝的记录均保留，边界见下文。

## 授权与来源

用户授权继续实施冷启动缓存入房，并推送 Debug 到模拟器自行测试。仅本轮 Debug 交付，不包含生产更新发布。

候选 0.4.53+2222，产品提交 e55cd1664f012f41ab8c1805366b1269d4176f0a，当前文档后继 b53e7387。工作树 C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat。16 个修改文件的最终 SHA 已由 final-source-manifest.json 核验；初始实现与增量分别完成 SPEC→QUALITY/security 独立审查。

## 实现与边界

- 有效缓存房间不再等待 SDK、联系人补充、持久队列打开或 SQL hydration 才 push 页面；同一页面和控制器在后台恢复后更新。
- 按消息列表的置顶、草稿和活动排序准备最多 40 个房间。用户点击优先，正在执行的一次读完成后即可重新排队，后台批次不会淘汰当前请求房间。
- 原始投影只属于最初 coordinator；后续 canonical 内存头从权威本地记录读取并绑定当前身份、Room、历史代次和 mutation revision，失效旧内容不能复活。
- 队列初始化期间可以浏览；队列就绪后才允许文字持久排队，实际发送继续检查加密、身份和通信状态。本地排队不会再误要求加密引擎已经能联网发送。
- 独立首屏缓存与旧式本地 SDK 恢复分别校验。隐私屏障、退群、发言权限、取消、账号或 Room 替换仍拒绝无效排队。
- 群头像交接从权威本地成员表有界补读缺失状态，不复用已失效头像元数据；缓存不可用不会阻塞正常 SDK 列表。

## 已完成证据

证据根目录：docs/verification/artifacts/2026-10-17/cached-room-entry/。

| 门禁 | 结果 |
| --- | --- |
| 原问题 RED | post-SDK SQL held 时 RoomPage 不存在 |
| 关键反例 | 隐私屏障阻塞 canonical 列表、同账号恢复复活旧投影、排队误用加密就绪均有 RED/GREEN |
| 初始专项 | 5 真实入口、94 单元、31 导航通过；分析无问题 |
| 首轮共享全量 | 6144 PASS / 9 SKIP / 8 FAIL，exit1，23分22秒；完整保留 |
| 全量发现修正 | 13 文件组 186/186 PASS，83秒，涵盖全部8失败及新负向；分析无问题 |
| 最终共享全量 | 6155 PASS / 9 SKIP / 0 FAIL，exit0，25分19秒；source_stable=true |
| 最终全局分析 | No issues，exit0，18.9秒 |
| 平台/源码契约 | 39 PASS；版本元数据此前18 PASS |
| 独立审查 | spec-code/quality-code 与 spec-delta/quality-delta 均 PASS |
| 诊断 APK | 0.4.53+2222 x86_64，固定75b31签名，重建/对齐/语义/资产逐项门禁全部通过 |
| 首次原生 | 4场景完成，独立场景未观察到目标SQL开始信号；exit1保留 |
| 同一 APK 原生重跑 | 五场景全部通过，222.156秒；首帧、头像、误离线、post-SDK/post-sync缓存入房及滚动断言均通过 |

首轮失败包括本地排队误用含加密就绪的权限判断和三处旧导航静态断言。两条旧字面预期在 f32c163e 基线也不存在，baseline JSON 仅证明精确源码断言，不冒充完整基线执行。最终通过是修正后的独立命令结果，不把首次 exit1 改写为通过。

原生诊断 APK SHA256 为 7eadfc1da2b9d5e30c16b922f80674f7a0f653ee92ea63040c6acbfa1eefc1cf。r2 复用同一已安装字节，UID10090、首次安装时间2026-09-26 04:06:20保持。测试使用合成数据和真实应用 main 入口，不操作安装账号的真实消息。

首次原生失败未在受控重跑中复现。补充确定性实验明确在无关旧读取被持有期间发生同步，目标缓存由有效变为失效；点击后目标自身SQL已开始，无关SQL仍被持有，等待的是目标自身SQL。两次一致结果、临时测试补丁和完整限制见 diagnostic-summary.md。该实验不解释首次原生失败，也不证明缓存失效时仍可即时入房。临时修改已恢复，交付源仍为 b53e7387；没有为通过测试放宽隐私失效规则。

Windows 原生测试使用已核验 Olm 3.2.15、SQLCipher 4.10.0 / SQLite 3.50.4 及独占短盘符。完整 scripts/verify.ps1 因缺本地 .env 未运行，不导入生产配置。iOS 未构建或设备验收。

## 普通 Debug 交付与实际观察

- 来源：b53e7387e9b3f1815f0e4f3aade08b6c5132aa52，target lib/main.dart；构建23:39:26–23:44:34+08。
- 最终 APK：artifacts/2026-10-17/cached-room-entry/debug-main-2222/final.apk，126,097,754字节，SHA256 `0ca7e72dd909e9c4cbb1a8f5ce1022d282ab156a3c29a454e2ea1bfb71382298`。
- 固定签名 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`；源码构建、常规重建、对齐、签名、清单语义、代码及资产校验全通过。
- install-main-2222：adb install -r成功，设备base.apk哈希相同，UID10090、firstInstall2026-09-26 04:06:20保持，普通main启动成功。
- cold-main-2222：首次实际录制为admissionRejected，观察到加载页；之后加密投影写入成功（15房间/92事件）。该轮不算缓存快速路径通过。
- cold-main-2222-r2：cacheAdmissionHit1031ms、firstProjectionContentFrame1349ms、fullSdkReady3957ms，三者共用main_entry时钟；不能与Android Activity或录像时钟混算。画面抽查为先出现带头像列表，无加载页及误离线toast。
- room-main-2222：第一个房间直接出现气泡并返回；内容短，不作为长历史滚动证明。room-main-2222-history：第二个房间直接出现气泡，滑动确实移到较早消息，返回列表。
- 录像仅本地存储，联系表以4fps抽查，不能代替原生夹具的逐帧断言。没有发送真实账号消息。
- final-audit.json：16个源码SHA再次一致、mobile clean、当前进程fatal/ANR匹配0、自建forward与V/W映射已清理。模拟器留在消息列表。

本轮未修改生产更新配置。缓存不存在或因身份/隐私/同步代次失效时，仍走受保护的本地恢复；不宣称所有冷启动、所有房间均无等待。首次原生信号缺失未复现，完整失败及同包重跑通过均保留。

当前证明范围：同账号恢复反例证明旧头不再可用且新许可可获取；不单独声称恢复后的新头已填充。后台同步后的新缓存可用性由独立实际 main 场景验证。延迟队列错误账号回调有明确守卫及控制器覆盖，未新增独立 RoomPage 错误账号 widget 场景。
