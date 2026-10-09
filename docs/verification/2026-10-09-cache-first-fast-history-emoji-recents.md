# 缓存优先、连续快滑、静态表情最近使用：私有 debug2212

2026-10-09 13:17:40–14:53:15+08，约96分钟，实施、独立规格/质量审查、共享/原生验证、常规重建和保数据安装完成。任务见[记录](../workflow/tasks/2026-10-09-cache-first-fast-history-emoji-recents.md)，范围依照[批准计划](../superpowers/plans/2026-10-09-cache-first-fast-history-emoji-recents.md)。未公开发布新版本或修改更新弹窗。

## 行为与根因

| 验收项 | 根因与结果 |
|---|---|
| C1 冷启动消息列表 | 房间预览修复、完整计数等可选任务仍挡住缓存发布。先安装缓存房间状态和预览，再后台整理；本地完成通知与远程sync分离，过期账号/页面任务不发布。 |
| C2 连续快滑 | 固定裁100行可能裁掉高气泡对应可见消息；拖动标记覆盖惯性阶段又阻挡窗口推进。现在按可见事件ID保留窗口，实际手指拖动与惯性阶段分别处理，窗口不超过200个UI模型，持续惯性时可以锚定推进。 |
| C3 快速切房/旧索引 | 首屏仍等待关联房间、提及恢复及可选索引路径。先用持久head IDs建立缓存气泡，再恢复可选状态；预览后台lane独立；退休租约和延迟提及恢复受取消/身份保护。 |
| C4 表情 | 每次重开默认静态；按账号保存16个去重最近使用emoji，最新在前，8列两行。身份未知只保留内存，不把token写进偏好键；动态tab保留显式选择与单枚直发。 |

未增加明文消息持久化；E2EE、认证及金融逻辑不变。源码位于managed worktree `C:/Users/Administrator/.codex/worktrees/android2205-sync-deadlock/StarChat`，未合并；基线b09bf2f214656c617a0171711d47f4089904e893叠加既有2211工作，不将整个HEAD差异归入本任务。

## 验证范围

- 全量Flutter 5757通过、9条件跳过；分析0问题；Python边界377通过、23条件跳过；UI契约34组件/535屏幕通过；policy三项通过。完整verify因本机缺.env未启动，未导入生产秘密，使用上述适用拆分门禁。
- SDK最终59项、集成64项、生命周期9项通过。真实Widget提及写入延迟、恢复瞬时失败后新事件重试、退休页面完成保护有RED→GREEN；缓存预览及百万copying旧索引有延迟RED→GREEN。两轮独立SPEC后QUALITY审查接受。
- Android原生缓存/生命周期15项通过；最终连续快滑独立1项通过；不能把初次合并16项中的一项测试观察器失败称作单次16项全绿。30次重叠10000px/s手势，窗口推进时同一可见事件偏差小于1像素。
- 原生emoji6项通过，含默认静态两行16个、56个WebP、12次快滑、10次真实键盘开合；默认静态动画entry为0，动态可见当前帧589824bytes。维护/加密旧历史原生24项通过，覆盖25万/百万索引、实际RoomPage切换和IME，helper清理与原IME恢复通过。
- 原生连续测试的异步观察最初触发TestAsyncUtils：最终以Finder/RenderBox和expectSync读取/断言，保持事件ID、1像素和窗口限制；最终host1/native1通过。全量门禁后仅此测试文件变化，生产源码和generated inputs一致，复用其余全量证据。`gate-reuse-receipt.json`绑定全量输入91085d0c…c6f89及构建输入f5eab556…a0d23。

全量首轮7个旧等待时机/固定100ms夹具失败、初次原生观察器失败和路径误填均保留日志；最终相关修正/重跑通过。未弱化计数竞态、准确成员定位、租约清理与账号隔离断言。原生静态SVG既有不支持filter告警保留，不属于框架异常。

## 交付身份

| 字段 | 值 |
|---|---|
| 包 | 0.4.43+2212，standard x86_64 debug，com.liuhetong.mobile.debug |
| 常规流程 | 源码Flutter→Apktool2.12.1解包重建→zipalign16→固定签名→26构建校验 |
| APK大小 | 125827617 bytes |
| APK SHA256 | 129ec7876b9030b217d9485831e716657bde01561fcd0d08134ada3f4498f129 |
| 签名证书SHA256 | 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff |
| 冻结源码清单 | f5eab55688d107490b3c079600310627339572cf1280367811817a75732a0d23，1941文件 |
| 锁文件 | 12ae67427fe7b17a65aa929773940cfef1ce97be4fe5240a925a373c771f191e，无升级 |
| 安装 | emulator-5556，14:53:15+08完成install -r，2211→2212，无卸载/清数据，firstInstallTime保持2026-09-26 04:06:20 |
| 启动 | 安装APK哈希一致、15秒PID稳定；Dart未处理/Flutter断言/框架异常/Java原生致命异常计数均0；只内存读取原始日志，不保存真实消息 |

证据根目录：`C:/Users/Administrator/.codex/worktrees/android2205-sync-deadlock/StarChat/docs/verification/artifacts/2026-10-09/cache-first-fast-history-emoji-recents/`，root下包括flutter/analyze/boundaries receipts、native最终日志/receipts、IME清理、gate-reuse、install/startup错误计数，run-20261009-145050-debug下包括artifact.json及构建验签/前后冻结校验。56动态资源仅注入此私有debug缓存。

## 仍需验证的边界

真机USB暂不可用，未证明Redmi/弱网release或iOS性能；连续手势与真实弱网响应同时发生的新专门组合用例仍缺，现有网络延迟及A-B-A为分开证据。首次安装无有效缓存时仍需网络。未知百万历史ID首次精确ordinal约8.8秒，缓存head绕开该查询；原生100房间/10个25万旧索引恢复约2.46秒。后台提及scanner完整未读消息体保留风险未改，不能宣称所有历史规模内存恒定或零卡顿。原生维护debug最高build帧314ms、emoji最高434ms，p95改善不等于全部帧流畅。

14:50:29+08只读正式Android仍0.4.42+2211、iOS0.4.36+2205、官网候选2209。本次未修改CloudFront、正式安装包或生产设置。后续需要真机覆盖升级/弱网连续手势验收；如用户授权公开发布，应另建ARM64 release并按平台分发门禁执行，不能分发此x64 debug。
