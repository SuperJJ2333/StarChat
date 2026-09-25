# MI 6 性能诊断 Debug 交付与实测

## 恢复入口

- 目标与授权：用户 2026-09-25 要求把诊断 Debug 包推送到 MI 6 供测试，并检测真实客户端及网络指标、寻找优化空间；未要求公开发布、服务端生产部署、代发消息/通话或资金操作。
- 关联计划：[交付与测量计划](../../superpowers/plans/2026-09-25-performance-debug-mi6.md)；原性能诊断[任务](2026-09-25-unified-performance-diagnostics.md)及[手册](../../performance/chatflow-performance-diagnostics.md)。
- 当前状态：隔离整合、源码门禁、常规重建与固定签名、MI 6 保留数据安装均完成。诊断提交 `8d044655` 基于 0.4.6/2165，已发布 Android 源码 `e7ba46a4` 为 0.4.7/2172；新 Debug 为 0.4.11/2174。真机已测启动、帧、设备至 Business/Matrix 的公开网络路径；设备当前在登录页，账号内操作待用户自行登录。
- 工作树：`C:/Users/Administrator/.codex/worktrees/performance-debug-mi6/StarChat`，分支 `codex/performance-debug-mi6`。root 负责文档、版本、构建、设备与整体测试；导航冲突与联系人/资料冲突分别由独立代理负责，文件所有权不重叠。
- 最后更新时间：2026-09-25 05:17 Asia/Hong_Kong。
- 下一步：用户自行登录后采集会话打开/Matrix/媒体/API 真实 trace。只读生产聚合确认 Synapse versions 处理约 1 ms，但网关/API 缺请求耗时与跨层 ID，Business 长尾暂无法细分；当前包无需再次安装。

## 验收台账

| ID | 场景及预期 | 当前证据 | 状态 |
| --- | --- | --- | --- |
| DBG-PERF-01 | MI 6 保留数据装入高于旧版的固定签名 Debug | 0.4.11/2174 APK SHA `3317ba91…`；设备读回一致，固定证书、首次安装时间、启动及零崩溃均验证 | 通过 |
| DBG-PERF-02 | 真机读取有界性能快照与帧指标 | VM 扩展启用；启动 1367 ms，首次六帧四慢帧；登录页返回前台五帧一慢帧。启动 trace 慢帧归属有漏计 | 部分通过，记录改进项 |
| DBG-PERF-03 | 区分设备传输、Business API 与 Matrix 状态 | 系统 Wi-Fi validated；无凭据 Business ready/Matrix versions 均 200；账号 Matrix 连接状态仍未知 | 公开链路通过，登录后待测 |
| DBG-PERF-04 | 提出有实测依据的优化空间 | HTTPS 探测长尾在 TCP/TLS 与一次 Business TTFB；需服务端时长相关证据。发送/通话不自动触发 | 初步完成，待账号内样本 |

## 版本与证据

| 平台/服务 | 实际版本 | 来源 | 包名/签名 | 证据 |
| --- | --- | --- | --- | --- |
| MI 6 安装前 | 0.4.10/2171 Debug | 上轮保留数据交付 | `com.liuhetong.mobile`；固定测试证书须在安装前读回核对 | `base.apk` SHA-256 `5f3ddee5e9396a31efb16c3aff9c185937f5203bb9b5f950825f1561148aaf20`，ADB `cbd0156b` online |
| 已安装候选 | 0.4.11/2174 Debug | Android 已发布源 `e7ba46a4` + 诊断 `8d044655`，整合提交 `c0688667` | 与现有测试证书一致 | APK 与设备 SHA-256 `3317ba916a39c88fb341509af91d55d21e819ba96951e11105cf2a400685e06c`；[验证报告](../../verification/2026-09-25-performance-debug-mi6.md) |

## 阶段计时

| 阶段 | 开始 HKT | 结束 | 类型/并行 | 结果 | 下一步 |
| --- | --- | --- | --- | --- | --- |
| 设备/工作流只读核对 | 2026-09-25 04:21 后 | 04:35 前 | 代理并行、root 审计 | 发现设备 2171 高于旧诊断分支 2165；确定使用 2172 已发布源码整合 | 代码合并 |
| 隔离整合 | 2026-09-25 04:31 后 | 04:46 前 | root 与两个独立文件所有权代理 | cherry-pick 六处冲突逐块合并，保留 2172 路由、联系人共享客服资料与个人资料功能；无未解决冲突 | 源码门禁 |
| 整合源码门禁 | 2026-09-25 04:38 后 | 04:46 前 | 工具/并行后核对 | Flutter analyze 无问题、定向 66/66、Flutter 全套 4277/9 跳过、Matrix 2108/9 跳过、mobile 108/1 跳过、后端诊断聚焦 166/1 跳过、OpenAPI 与仓库策略均退出 0 | 冻结与构建 |
| APK 常规重建与验包 | 2026-09-25 04:50 | 04:54:51 | root；源码/DEX/resources/Manifest/签名 | 构建脚本退出 0，最终 APK SHA `3317ba91…` | 设备安装 |
| MI 6 保留数据安装 | 2026-09-25 04:58 | 05:00:27 | root；首次脚本日期参数预检失败、修正后成功 | `adb install -r` 成功；设备读回版本/SHA、原首次安装时间、进程、零崩溃均通过 | VM 快照 |
| 真机诊断与网络公开路径 | 2026-09-25 05:01 | 05:09 后 | root；VM 快照、Android curl | 启动与帧指标可读；Business/Matrix 各五次均 200，连接/TLS/TTFB 长尾见报告 | 用户自行登录后继续 |
| 生产侧只读时窗核对 | 2026-09-25 05:10 后 | 05:17 前 | 独立代理；网关/API/Synapse 日志聚合 | 各 5 条公开请求均 200，Synapse versions 约 1 ms；网关/API 无耗时与跨层 ID，Business 4.791 s 无法定位 | 后续受控变更补 timing/correlation |

总墙钟：完成后按实际记录；不从并行步骤相加推算。

## 交接与回退

- 当前设备已保留数据安装 2174 Debug。没有降级、卸载或清数据；覆盖安装前的旧包 SHA 与安装后的新包 SHA 均读回。若需回退必须先评估版本与数据兼容，不能直接使用 `adb install -d`。
- 只采集封闭诊断字段和工具状态，不持久保存完整 logcat、用户身份、消息、Token、IP 或密钥。
- 已构建并装机；未公开发布或部署服务端。VM 临时 ADB forward 每次探测后移除。登录前账号内指标不可观测。
