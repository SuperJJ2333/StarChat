# “我”页、邀请码与朋友圈互动任务记录

## 恢复入口

- 目标与授权：用户于 2026-09-24 明确要求五组精准行为；沿用上一轮 MI 6 Debug 保留数据测试渠道。只修改本计划拥有的源码及合同，生产发布遵循现行 runbook 与实际授权边界。
- 计划：[实施计划](../../superpowers/plans/2026-09-24-me-invitations-moments-interactions.md)；产品依据 `2026-08-12-starchat-product-modernization-design.md`、`2026-08-24-wechat-moments-completion-design.md`；资料字段合同见 [ADR-0085](../../adr/0085-profile-visible-character-limits.md)，领域与 Quality/Security 决策复审已记录。
- 当前状态：五项需求及最终审查补漏已实现、验证，业务 API/worker 已生产发布；MI 6 已保留数据安装 0.4.10/2171 Debug。正式 Android 最新版本是用户确认的 v0.4.6/2165，未修改正式分发。真实用户业务体验待反馈。
- 负责人及工作树：`/root` 集成，`/root/group_ui` 导航/Flutter资料，`/root/delivery_audit` 邀请测试与服务端资料，`/root/moments_ui` 朋友圈；`D:\pythonProject\outsource\StarChat\.worktrees\online-room-refresh`，基线 HEAD `8ed729a1`，保留前次未提交修改，不并行编辑同文件。
- 最后更新：2026-09-24 10:06 HKT。
- 下一步：用户在 MI 6 上按五项验收路径复测并反馈；如反馈问题，先查本记录中的源码/镜像/设备身份再做增量修复。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| ME-NAV | 我页全部同级子页隐藏 Tab、无底部遮挡；各种返回恢复；会话失效清旧页 | 已实现根 Navigator/会话清栈 | 导航及 SessionGate RED→GREEN，最终 Flutter 全量 4120/9 | 2171 Debug | 用户复测手势/系统返回 |
| ME-INVITE | 实际倒序邀请历史，分钟/畅聊号、空态与分页 | 已接入现有认证 API，支持滚动加载 | 真实入口 2 例 RED→GREEN，服务端现有历史分页 | API 路由在位、2171 Debug | 用户复测真实邀请数据 |
| ME-PROFILE | 昵称 12、签名 20 字素，实时计数/精确弹窗/提交复验 | Flutter 与服务端统一字素校验，数据库增量扩列 | ADR-0085 领域/安全复审、API/Flutter RED→GREEN、隔离迁移原数据不变 | API c41dfffc/schema0088、2171 Debug | 用户复测输入法/历史长资料 |
| ME-MOMENTS | 我页仅本人已发布内容，更多→全部互动、详情定位与授权预检 | 已实现本人列表、互动分页和详情授权预检；临时身份读取失败后仍保留更多入口但打开前实时验权 | Flutter/后端专项及全量通过，失效历史保留泛化内容 | API c41dfffc、2171 Debug | 用户用不同可见范围复测 |
| ME-REMINDER | 评论/回复独立通知、倒序分页、红点、失效历史提醒仍可见但不可打开 | 独立朋友圈通知及未读入口，前台恢复/停留我页限频刷新 | 后端互动/权限/分页及 Flutter 红点/跳转 RED→GREEN | API c41dfffc、2171 Debug | 用户复测好友互动 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| 起点 MI 6 | 0.4.10+2169 Debug | 候选工作树 `8ed729a1`+未提交变更 | `com.liuhetong.mobile`，固定证书 `75b31c66…` | 上轮最终 APK SHA256 `6168daef6120eb28344eb55d21bbab4a17b72375400807bc1bd1197ab1540a57` | 上轮 2026-09-24 验证，见[前次记录](../../verification/2026-09-24-group-moments-wallet-debug.md) |
| 起点业务 API | `sha256:f63cb266617819f5f407bba4bac0622fce4bfca83581f6e5ceb72f9c17d92f91` | 上轮最小增量 | 生产镜像 | 上轮部署证据 | 上轮 2026-09-24 验证 |
| 正式 Android | v0.4.6/2165 | 已发布基线 | 官网/更新弹窗正式签名 | [前次正式发布记录](../../verification/2026-09-23-avatar-album-android-release.md) | 本轮未更换 |
| 最终 MI 6 | 0.4.10/2171 Debug | `8ed729a1` + 本轮/上轮工作树 | `com.liuhetong.mobile`，固定测试证书 `75b31c66…` | [APK](<C:/Users/Administrator/.codex/visualizations/2026/09/23/01a0d059-a062-7cd3-b140-f324cc27a599/docs/verification/artifacts/2026-09-24/me-invitations-moments-interactions/android-debug2171/final.apk>) SHA256 `5f3ddee5e9396a31efb16c3aff9c185937f5203bb9b5f950825f1561148aaf20` | 2026-09-24 10:02 HKT 安装验证 |
| 最终业务 API | `sha256:c41dfffc30a3b52f0af179cf58aebfb0ce58db26c09d333881906a01755b7ba9` | 正式 v0.4.6 功能+本轮/上轮最小增量 | 生产镜像 | [部署验证](../../verification/2026-09-24-me-invitations-moments-interactions.md) | 2026-09-24 09:41 HKT 复核 |
| 最终 worker | `sha256:90696ffa848299cc157daba0a80b0d3ce26a2693c13f1d5b0138ac70c740f1bd` | 正式 v0.4.6 基线 | 生产镜像 | 同上 | 2026-09-24 09:41 HKT 复核 |

完整测试与发布现场见[验证记录](../../verification/2026-09-24-me-invitations-moments-interactions.md)。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 根因调查/计划 | 2026-09-24 07:47 HKT | 2026-09-24 07:57 HKT | 主动/并行只读 | nav / invite / Moments | 三域报告；本计划 | RED 实施 |
| ADR、并行 RED/GREEN 与演示 | 2026-09-24 07:57 HKT | 2026-09-24 08:15 HKT | 主动/并行实施 | Flutter、API、前端 | ADR-0085；演示 `npm test` 305/305 与 UI 合同 32 组件/429 屏；浏览器查看邀请、我的朋友圈、互动不可查看、昵称截断弹窗、我页返回 | 等域冻结与完整回归 |
| 生产基线只读检查 | 2026-09-24 08:12 HKT | 2026-09-24 08:15 HKT | 工具/只读 | 根 | 现网 API 镜像 `f63cb266…` healthy、worker `237162be…` healthy；现网 API 镜像缺少数据库已记录的 `0087_support_payout_workflow` 迁移文件，`alembic current` 失败；本次候选须补齐 0087 与 0088 后在隔离恢复库验证 | 冻结最小覆盖清单 |
| 源码冻结/独立复审/全量门禁 | 2026-09-24 08:15 HKT | 2026-09-24 09:25 HKT | 并行/工具/返工 | Flutter、API、根 | 审查发现并修复资料审计明文、重复回放审计、通知游标与安全存储异常；RED→GREEN；`verify.ps1` 09:18 完成、Flutter 全量 4114/9 于 09:25 完成、analyze0 | 构建/隔离恢复 |
| Android 常规重建与真机安装 | 2026-09-24 08:55 HKT | 2026-09-24 09:00 HKT | 构建/设备 | 根 | 2170 Debug 固定签名、资源/DEX/manifest 复验、设备 SHA 一致、首次安装时间未变、启动正常 | 用户业务验收 |
| 生产隔离恢复与配置纠偏 | 2026-09-24 09:00 HKT | 2026-09-24 09:37 HKT | 备份/迁移/故障恢复 | 根 | 137 表/225466 行原值不变，schema0088；第一次切换旧环境导致服务配置校验失败并立即恢复；与已发布 v0.4.6 环境比对，恢复 17 个缺失键和 1 个差异值，真配置预检通过 | 第二次切换 |
| 生产精确切换与复核 | 2026-09-24 09:37 HKT | 2026-09-24 09:41 HKT | 工具/服务 | 根 | API c41dfffc、worker90696ffa healthy/零重启，其他22容器不变；HTTPS ready200、未授权401、311 OpenAPI路由、日志0新错误 | 用户验收 |
| 最终入口补漏与 Debug2171 | 2026-09-24 09:41 HKT | 2026-09-24 10:03 HKT | 并行审查/全量复测/构建/设备 | 群名、互动、根 | 建群/编辑群名 12 字、互动红点前台/停留刷新与“更多”容错 RED→GREEN；Flutter 4120/9、analyze0、最终 APK `5f3ddee5…` 保留数据安装、设备读回一致 | 用户业务验收 |
| 最终证据和生产复查 | 2026-09-24 10:03 HKT | 2026-09-24 10:06 HKT | 只读/文档 | 根 | 94 文件源码清单哈希稳定、文档16条本地链接存在、`git diff --check` PASS；生产 API/worker 再次 healthy/零重启、HTTPS 200/401、零新错误 | 用户业务验收 |

本轮根因/实施/构建/发布墙钟约 2 小时 19 分钟（07:47–10:06 HKT），含并行、首次切换后的恢复及最终补漏；阶段边界为观察近似值，不冒称精确计时。

## 交接与回退

- 已确认根因：邀请入口未注入现有历史网关；我页多数子页推入 Tab 内 Navigator；我页朋友圈误开好友 feed；现有通知仅作者评论/赞且过滤失效历史行；服务端 profile 字段按 code point 64/140 与列宽限制。
- 待办：仅真实账号/好友在 MI 6 上复测五项交互并反馈；自动化/容器健康不替代该反馈。
- 已发布与候选：服务端 API c41dfffc、worker90696ffa、schema0088；MI 6 为内部 Debug2171，正式 Android v0.4.6/2165 未变。2170 是本轮中间测试包，不再是最终设备状态。
- 生产备份/恢复及漂移：服务器私有目录 `/opt/starchat/releases/me-invitations-20260924/` 中保留迁移前与 0088 后备份、候选及兼容回退配置/镜像；兼容回退 API f96c43cc/worker90696ffa，必要时按现时镜像/schema再次核对。首次失败切换恢复过旧 API f63cb266/worker237162be，不能把旧镜像当最终运行态。
- 运行中的任务/隧道：无持久服务器隧道；工作树保留未提交变更。
- 下次恢复：先核对 `git status`、生产 API/worker/0088、MI 6 build2171 与本台账，再根据用户反馈做定向验证。
