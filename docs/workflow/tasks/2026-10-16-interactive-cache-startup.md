# Android 0.4.48 启动与入房交互缓存

## 恢复入口

- 用户要求：冷启动直接使用本地会话列表，恢复期间可切页/进房；入房先展示缓存气泡，可滚动/发送；改进 Debug 安装模拟器供用户测试。
- 授权范围：客户端改进及模拟器 Debug 安装；未要求公开发布。
- 当前阶段：用户已批准方案，实施中；Task1已通过规格及质量复核，Task2聚焦回归中，尚未构建或安装。
- 源码基线：活动树 `C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat`，HEAD `74cf7217`，分支 `codex/android-consent-20261016`。primary main `5c83a08a` 不是最新移动基线。两树均有其他任务文档改动，实施须隔离。
- 负责人：root；工作树 `C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat`，分支 `codex/interactive-cache-startup-20261016`。计划：[交互缓存实施](../../superpowers/plans/2026-10-16-interactive-cache-startup.md)。下一步：Task2冻结后独立复核，运行共享门禁，构建并保数据安装。
- 更新时间：2026-10-16T20:51:22+08:00。开始精确时间未知；调查工具在本轮聊天留存，未估算耗时。

## 已核实事实

1. `installation_startup_gate.dart` 在 prepare/reconcile/start 完成前不创建应用内容；1秒显示安全占位，3秒显示具体阶段。`main.dart` 的 startApplication 在返回应用前等待 retained Matrix DB 打开。不能仅删除文案解决阻塞。
2. `app_home.dart` `_buildMessagesTab` 在 Matrix 未 ready 时使用 `previewOnly: true`，`matrix_home_page.dart` 显式禁用缓存会话点击与入房；旧2216批准规格明确只读预览，不等于本次交互预览完成。
3. `room_page.dart` 等待 `openLogicalRoomTimeline` 后才创建 controller；空列表/controller为空时展示“正在读取本机消息…”。需把首屏缓存投影及输入排队与完整时间线挂载分离，同时保持账号/租约/隐藏消息/权限边界。
4. adb只读确认 emulator-5556 在线，存在 `com.liuhetong.mobile.debug`；未卸载、清数据、发送消息或改网络。

## 拟议验收

- S1：已有有效本地账号，安全本地检查后展示缓存列表；后台同步期间可切tab/进入已有会话。
- S2：缓存房间先绘制近期气泡，恢复不清屏、不重置滚动位置；历史按页读，取消过期请求。
- S3：本地安全存储就绪后，发送持久入队并显示待发送，通信就绪后沿现有权限和E2EE链路发送；不冒称服务端已送达、不重复发送。
- S4：退出/切账号/撤销/密钥不可用不泄漏旧缓存，不跳过安装连续性检查；首次无缓存和失败状态如实展示。
- D1：聚焦RED/GREEN、共享门禁/分析、规格再质量审查、固定签名常规重建，保数据install-r；用户自行功能测试。无新包交付事实。

设计边界：正常已登录且有缓存路径减少整页加载；冷进程仍须读取磁盘/安全存储，不承诺所有设备绝对零延迟。发送点击可立即入队，不意味着恢复前已完成网络投递。

用户已批准上述方案实施。新工作树interactive-cache-startup，分支codex/interactive-cache-startup-20261016，基线74cf7217。Task1房间→Task2启动→Task3交付。根负责文档/构建，实施代理单写，独立审查。

2026-10-16T21:36:52.8318365+08:00 Task1 commits44f079ba+981ac950；Task2单写进行中。证据：[交付验证](../../verification/2026-10-16-interactive-cache-startup.md)，详细时间账本在 artifacts/2026-10-16/interactive-cache-startup/progress.md。Debug目标0.4.49+2218，无生产发布。

