# main 分支集成核验（2026-09-10）

用户授权合并 main、提交并审计其他分支的同类遗漏。对应计划：[main 集成计划](../superpowers/plans/2026-09-10-main-integration.md)。

## 来源及取舍

- main 起点 `be14e743`；先快进 release 分支 `codex/redmi-polish-20260909` 的 `05d40c2d`，再合入 `codex/mobile-parity-20260909` 的 `66bd17c6`。
- Android 源码版本保持 `0.3.73+2077`。保留 release 的朋友圈行内评论、主题反应、隐私、共享身份及支付 PIN，兼容 parity 的账号缓存、签名媒体 URL、会话恢复和 iOS 更新隔离。
- `codex/wallet-safety-mi6`、`codex/ios-0353-background` 以及 fetch 后的 `origin/codex/ios-compatibility`、`origin/codex/wallet-safety-mi6` 均没有 release 之外的独有提交。旧 iOS 工作树的有效未提交内容已被 main 历史包含。
- 原根目录保存 487 个候选文件的源码快照及 SHA256，逐项排除已被更新实现覆盖的旧支付/身份/版本代码。补入后台 UI、企业下载、媒体去重/容量、诊断工具与本次 @/历史/日期修复；另保存并纳入 10 个快照之后的文档/测试增量。
- 独立任务“实施媒体去重与千人群扩容”仍在原根目录运行，因此不对原根目录 stash/reset/switch，不删除旧分支或工作树。main 在隔离集成目录检出，后续发布应明确从 main 构建。

## 冲突解决

- 朋友圈融合 release 的交互与隐私以及 parity 的账号隔离缓存/确认后写入；评论图片补传媒体账号和来源，避免签名 URL 变化导致缓存身份失效。
- 聊天功能通过 MatrixRoomLease 公共能力接入，保持已合入的直接会话唯一协调和 E2EE 边界。未读 @ 以首次本地状态的原已读事件为边界，普通已读回执不清空逐条未查看集合；仅气泡确实可见达到阈值后清除。历史与日历加载保留分页、取消代次和账号生命周期保护。
- 登录响应保留 Matrix 身份字段，同时完整保留管理员会话/CAPTCHA 路由。错误响应同时具备 no-store 与适用时的 Retry-After。
- 新增 `0060_merge_release_parity`，仅合并两个迁移历史终点，无表结构或数据操作；release preflight 显式固定新终点并保留所有独立资金门禁。直接会话迁移测试限定自己的升级区间，避免把无关既有钱包约束升级当成会话破坏。
- Figma/UI ledger 按记录增量合并，保留 19 组件、331 页面。历史未同步的远端设计状态仍如实保留，未声称新完成 Figma 同步。
- 修复测试隔离：显式缺失的 Compose 参数用空进程值覆盖 .env.example，确保 :? 门禁测试真正验证缺失；不放宽生产默认与门禁。

## 验证记录

- 定向迁移及 release 基线：13 passed；迁移/身份/直接会话首轮共 38 passed，区间测试发现并修复一项范围冲突。
- 后台界面完整 Node 测试：115 passed；UI contract drift：PASS，19 components / 331 screens。
- 非移动端规格复核后执行质量/安全复核：无阻断问题；Compose 根目录与 infra/compose 路径渲染等价，保护挂载保持只读且禁止自动创建目录。
- 初次统一验证发现 .env.example 干扰缺参测试，修正后定向 10 passed；后续完整执行与失败项复验如下。

原始日志、源码快照、分支引用、逐文件清单保留于本地 `docs/verification/artifacts/2026-09-10/main-integration/`，不纳入提交。未运行线上迁移、发布或 APK 安装。

## 最终执行结果

- Flutter 全量：`flutter test --reporter expanded`，**1749 passed**；完整 `flutter analyze` 无问题。首轮 4 项失败包括遗漏的2077头像身份（已恢复）及旧加密/账号测试夹具（已修正，未放宽生产校验），最终整套重跑通过。
- 后端完整执行：**1539 passed、37 skipped、1 failed**，失败为 parity 的旧测试尝试创建外部图片，与2077作者上传归属校验冲突。修正为明确断言外部媒体返回422、有效作者上传参与缓存验证、无效历史媒体不授予访问URL；该文件 **5 passed**。
- 完整后端执行之后使用 `PYTEST_ADDOPTS='--lf --last-failed-no-failures=all'` 再执行原样的 `pwsh -NoProfile -File scripts/verify.ps1`：后端失败项 **1 passed**，没有重新运行已通过的1539项；其他类别均完整运行。最终 **Verification: PASS**。这是一轮完整执行加失败项定向复验，不把定向复验称为第二轮后端全量。
- 最终脚本：Infra **115 passed**；Getui bridge **28 passed**；Matrix bot **9 passed**；Python mobile boundary **66 passed**；UI contract、197个Python文件AST、业务API导入、单迁移终点及完整离线升级SQL、OpenAPI与Compose渲染全部通过。
- 37个跳过项保留原有数据库/并发前置条件（隔离PostgreSQL连接未配置，或SQLite不支持该验证）。本轮没有实际线上迁移或真实资金启用。现有依赖弃用提示为 Starlette/httpx、Pydantic配置及Alembic配置兼容提醒，未通过忽略规则掩盖。
- 两轮审查发现并修复 @ 扫描撤销遗漏和超长气泡阈值定义：分页间及持久化前检查账号/租约撤销；判定为 `min(气泡高度, 视口高度) × 50%` 连续可见500ms，且必须前台及当前路由。新测试先红后绿；最终复审无阻断项。
- Git 暂存区空白检查通过；补丁文本的必要空白上下文按现有仓库惯例用精确路径属性保留，未改写补丁内容。源码/文档清单排除本地运行日志、密钥与生成工件。

本轮只整合并提交本地源码，未推送远端、重新打包或覆盖安装APK。正式发布应使用本次 main 检出目录，并另按安卓重建签名运行手册进行。
