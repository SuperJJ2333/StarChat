# 视频转码诊断、四位 Build 与雷电 Debug 交付

## 恢复入口

- 目标、授权与边界：用户 2026-09-26 要求按 MI 6 诊断结论优化、支持四位 build 显示，并向雷电模拟器推送 Debug 测试。仅 Debug 候选；不发布生产/API/iOS/官网，不更改 E2EE 或压缩失败拒绝原片策略。
- 关联计划：`../../superpowers/plans/2026-09-26-video-transcode-build-ld.md`；起始证据：`../../verification/artifacts/2026-09-26/debug-jank/device-findings.md`。
- 当前状态：实现、门禁、APK 重建验签及雷电装机完成；真实视频发送待用户在独立 Debug 包登录后复现。
- 负责人、工作树、文件所有权、源码 commit：root 协调；`C:/Users/Administrator/.codex/worktrees/auth-login-2178/StarChat`，分支 `codex/auth-login-2178`，基线 `9ad2eb77`，实现 commit `d7d09ffb3f5b61c0ca1475c92e14dd182b7a7171`；文件所有权见计划。
- 最后更新时间：2026-09-26 04:19 Asia/Hong_Kong；精确开工时间未记录。
- 下一条具体操作：用户在雷电 `com.liuhetong.mobile.debug` 登录并复现一次短视频发送后，读取本地 `ext.chatflow.performance` 对应 `video_prepare` 记录，确认 native 失败/取消及两档真实耗时；不采集视频内容。
- 验证报告：`../../verification/2026-09-26-video-build-ld.md`。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| BLD-1 | Android 2179 非分包完整显示/上传/更新比较，已知 split ABI 偏移仍正确 | 已实现 | RED exit 1；GREEN 8 项 exit 0；关于页/强更测试；雷电 runtime 2179 | 雷电 Debug | 已验运行时 build；关于页未登录不可打开，但 widget 测试通过 |
| VID-1 | 原生失败/取消返回封闭代码且无路径/异常原文 | 已实现 | RED exit 1；GREEN 5 项 exit 0；Kotlin 编译 exit 0 | 雷电 Debug | MI 6 具体编解码器原因仍需输入复现 |
| VID-2 | normal/aggressive 分别有本地同操作耗时/结果；失败转码分类真实 | 已实现 | 聚焦 51 项 exit 0；本地/上传出口 11 项 exit 0；完整 Flutter 4333 项 exit 0 | 雷电 Debug | 雷电真实发送需登录；无用户视频测试 |
| LD-1 | 固定签名并行 Debug 安装/启动且不触碰旧包或 MI 6 | 已完成 | 重建 18/18 步 exit 0；ADB install/start exit 0；HTTPS Business/Matrix 均 200 | 雷电本地 | 该模拟器装机前未列出旧主包；未执行卸载/覆盖 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| 雷电模拟器旧主包 | 装机前未列出 | 不适用 | `com.liuhetong.mobile` | ADB `pm list packages` 未发现；未执行卸载 | 2026-09-26 |
| 新 Debug 候选 | 0.4.13+2179 | `d7d09ffb` | `com.liuhetong.mobile.debug` / 固定测试身份 `75b31c66…ba61fff` | `artifacts/2026-09-26/video-build-ld/run-20260926-040300-ld/final.apk`；SHA256 `0dd6ba52dc7cc4c8414ebf737d015963461395679fe4882091f3b251c32e070b` | 2026-09-26 04:06 起雷电本地 |

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 审计 | 2026-09-26 03:25 前，精确时刻未知 | 约 03:35 | 主动/并行 | build/视频/雷电 | MI 6 诊断、源码和设备只读检查 | RED 测试 |
| 实现与规格/质量审查 | 约 03:35 | 约 03:55 | 主动/并行/返工 | build/plugin/trace | RED/GREEN、取消不误归类、非有限时长清理；出口隐私测试 | 冻结源码 |
| Flutter 与仓库门禁 | 约 03:40 | 约 04:18 | 工具等待为主 | Flutter/verify | analyze 0、Matrix 0、最终完整 Flutter 0、`verify.ps1` 0；首次完整测试并发编辑 exit 1，复测 0 | 验包 |
| Debug 构建/重建/验签 | 约 04:03 | 04:05:43 | 工具等待为主 | build | 18/18 步 exit 0；产物 SHA 与固定证书见报告 | 雷电安装 |
| 雷电安装/启动/探测 | 约 04:06 | 约 04:18 | 工具/主动 | emulator-5556 | install/start exit 0；runtime build 2179；HTTPS 两端点 200；本地性能扩展启用 | 用户真实发送反馈 |

## 交接与回退

- 已确认根因/已排除假设：2178 视频失败在本地转码阶段，队列约 1 ms、未进入上传；原生失败/取消均折成 null，无法分型；Android build 2178 被 `% 1000` 错截为 178。2179 已解决诊断缺口及四位 build 显示，但具体 MI 6 编码器失败条件仍未知。雷电装机前旧主包实际未列出，不再把先前审计中的旧包状态当作实时事实。
- 待办及验收缺口：新 Debug 包无登录态，尚不能完成真实视频发送验证；其余 BLD-1/VID-1/VID-2/LD-1 的可独立验收部分已完成。
- 已发布与仅候选的区别：仅雷电安装并行 Debug；生产、iOS 与 MI 6 未改。
- 回退：可停止或移除本任务并行 Debug 包；未改其他包或用户数据。
- 运行中CI/命令/自己创建的隧道：无。
- 下次恢复先检查的事实：工作树状态、设备序列号、目标 build 是否仍可用、签名身份和任务验收台账。
