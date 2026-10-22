# Android 2233 聊天定位修复验收

日期：2026-10-21。任务：[记录](../workflow/tasks/2026-10-21-timeline-scroll-position.md)，计划：[执行范围](../superpowers/plans/2026-10-21-timeline-scroll-position.md)。

## 范围与根因

针对用户2232反馈的历史浏览被拉回最新、冷启动停在旧图片。源码基线1036a81e；候选0.4.64+2233，最终冻结fb15a9a8（实现de139fbc、22f0dd26及坐标记账修正；b31237f3仅夹具lint修正）。

1. 原RoomPage将恢复后的“最新自发消息”误判为新发送，触发post-frame跳转。现在只接受当前页面明确新发送意图，恢复outbox/回执不重置历史窗口；异步发送完成不覆盖后来用户手势。
2. 缓存补齐和媒体尺寸变动经过多轮惰性布局，原最新跟随标记单次消耗，可能停在旧几何边界。现在同帧布局持续跟随，显式发送跟随跨布局保持，用户手势/程序定位离开立即撤销待跳转及跟随。
3. 阅读历史时，同一事件ID的较新气泡高度变化仍会影响坐标。空闲时用可见气泡作布局中心，后续补齐保持该中心；正在拖动/惯性滚动保持原路径。
4. 原点校正同步更新页面的上一滚动坐标，不把布局调整计入阅读距离/方向。最新边界暂时估计不足时，必须实际看见最新行才重置阅读距离。

上述为可复现代码/宿主证据，不等于已在用户真机逐条复现两种现象。身份、加密、业务授权、财务载荷及生产更新配置未修改。

## 证据

目录：`artifacts/2026-10-21/timeline-scroll-position/`（非Git本地证据）。

- `anchor-red-r2.log`：恢复自发旧消息导致150→0；后续真实RoomPage后台更新回归通过。
- `cold-red.log`：补齐缓存后最新边缘余75px；`geometry-red.log`：相同ID中较新气泡变高造成历史位置移动。
- `recovery-red-r3.log`/`recovery-green.log`：outbox恢复错误回最新，修复后84PASS。
- `direct-red.log`/`direct-green.log`：直接发送意图补齐，25PASS；`direct-media-impact.log`23PASS。
- `components-final.log`11PASS：最新边缘、同ID媒体高度、无父重建布局、历史中心、拖动/惯性、导航取消待跳转。
- 启动夹具在主动发送后重新建立历史阅读位置，固定既有可见中心，8px边界限制不变；所有安全/单次发送断言保留。原任意文本坐标不能跨多条变高气泡同时保持。早期夹具查找/编译失败保留，不能计作通过。
- 审查顺序：scroll_root_review SPEC PASS → scroll_quality_review QUALITY PASS，见`final-review.json`。该轮随后仅修正测试语法/lint；后续坐标记账改动另经origin-final-review.json记录的顺序审查。
- 静态检查：`final-analyze.log`无问题。最终共享全量6378PASS/9既有SKIP/0FAIL（另893 harness），analyze_exit=0/test_exit=0/source_stable=true。2026-10-21 19:51:58–20:03:22+08，测试657.237s，分析+输入核对总684.46s。见full-receipt.json/full-summary.json；前次23失败均在最终原命令中通过。
- origin-impact-final.log50PASS，含真实RoomPage后台恢复、连续滑动、生命周期、可变高度及发送后导航。origin-final-review.json为补充SPEC→QUALITY PASS及输入hash。此前全量4890/9/23后取消，旧绝对偏移断言与清理级联及真实坐标记账缺陷已区分，保留origin-accounting-r1-*记录。
- 聚合verify预检缺工作区`.env`，未执行；未复制生产凭据绕过环境要求。

## 交付状态

0.4.64+2233普通main Debug/x86_64，2026-10-21 20:05:55–20:12:00+08完成源码构建、Apktool2.12.1重建、zipalign16KiB、固定75b31签名及重解包语义校验。所有步骤exit0；原始与重建Flutter/native资产逐项一致。最终APK126163290B，SHA256 `fa8cd9405725fa11933c714daef848e111b7256793f52b8171d71eaaa683f3fe`，绑定源码`fb15a9a8a445a4dbfea1bce93867ca54089b2801`。

20:12:39–20:13:03+08以install-r覆盖原emulator-5556，设备APK与本地同SHA；UID10090和firstInstallTime2026-09-26 04:06:20保持。真实MAIN/LAUNCHER冷启动及存活检查PASS，随后前台activity仍为本Debug。

原生UI层级工具只返回dump路径，没有取得XML；未把真实账号的群聊滚动标为通过，也未保存消息正文或发送测试消息。原故障房间的实际滚动及冷入房位置待用户复测。正式2232更新弹窗与下载入口未改动。

完整宿主/安装证据位于 `C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat/docs/verification/artifacts/2026-10-21/timeline-scroll-position`；构建产物位于 `D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-21/timeline-scroll-position/debug-2233-main-fb15-r2`。首次Gradle parent-null失败日志独立保留；未通过改移动源码解决构建环境问题。
