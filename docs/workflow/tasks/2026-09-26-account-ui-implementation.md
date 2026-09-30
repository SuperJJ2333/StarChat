# 账号 UI 正式实施任务

## 恢复入口

- 授权：用户已批准单文件 HTML 并明确“没有问题，请你正式实现”（2026-09-26）。本任务为四项需求的客户端/服务端正式实现与隔离验证；不授予生产发布、真实OTP、真实账号写入或安装权限。
- 计划：[实施计划](../../superpowers/plans/2026-09-26-account-ui-implementation.md)；ADR：[0085](../../adr/0085-account-credentials-and-otp-password-recovery.md)；[已批准设计](../../superpowers/specs/2026-09-26-account-ui-review-design.md)。
- 当前状态：四项需求正式源码实现、领域与独立质量/安全复审完成，已回填D盘。最终Flutter4002、frontend316、PG9、worker/OpenAPI128、主目录交叉回归62均通过；原verify的4失败已由最终相关门禁闭环，原退出1如实保留。详见[正式验证报告](../../verification/2026-09-26-account-ui-implementation.md)。
- 工作树：`C:/Users/Administrator/.codex/worktrees/account-ui-implementation/StarChat`，`codex/account-ui-implementation`，基线HEAD `b9eca8a419614112b085439445b7fd031027a740`。原D盘工作区诊断等修改保持；仅复制本任务批准的review与记录，不带`.env`或秘密。
- 所有权：后端代理identity/mail/相关tests；移动代理Flutter/pages/client/tests；前端代理HTML/catalog/styles/registry/tests；主代理docs/OpenAPI/集成门禁。不得并发编辑相同文件。
- 实际阶段记录：14:45:36 +08:00恢复；14:49:13工作树干净基线与Flutter/Python预检观察。此前审阅外部等待不计为实现工时。
- 下一步：源码任务完成。后续若领取安装包/发布，按固定重建与签名流程制作新版本，并在有授权的测试账号和设备上验收真实双渠道验证码；不得分发本轮源码编译中间APK。

## 验收台账

| ID | 预期 | 当前状态 | 证据/发布/缺口 |
| --- | --- | --- | --- |
| AC-01 | 个人信息计数隐藏，空/有值/保存后固定左标签 | 源码通过 | 空/有值/保存/320px文字缩放测试；保留64/140服务端约束 |
| AC-02 | 账号安全三入口，通用/聊天群偏好真实保存 | 源码通过 | 真实gateway、失败恢复、超时等待真实PUT后权威重读 |
| AC-03 | 两条入口共用邮箱/手机OTP改密，预先验证绑定 | 源码通过 | 已验证绑定/固定身份；同family可信refresh与手工替换/新登录迟到响应均通过 |
| AC-04 | 邮箱旧渠道证明→新邮箱验证→权威摘要更新 | 源码通过 | 原渠道成功起5分钟证明、纯手机账户证明当前手机 |
| SEC-01 | 错误/过期/重放/跨用户/改绑/供应商故障/并发阻断 | 后端复审通过 | 71专项/9PG；统一等待、deadline、UTC复查、脱敏 |
| SEC-02 | 保留refresh撤销/24h hold、旧reset兼容、E2EE边界 | 源码通过 | refresh撤销/24h hold与旧协议保持；不恢复聊天密钥、不删除历史 |
| UI-01 | registry、正式catalog、Flutter状态/token一致 | 通过 | 33组件/447画面、10浏览器检查；批准review SHA不变 |

## 工具与证据

预检：Flutter3.44.9/Dart3.12.2，Python3.12.10，SQLAlchemy2.0.52，pytest8.4.2。所有shell为pwsh.exe UTF8无BOM、PythonUTF8环境。临时证据只在 `docs/verification/artifacts/2026-09-26/account-ui-implementation/`。

## 交接

本轮已完成源码编译门禁，未制作最终重建安装包、安装或部署。4186保留供正式catalog与审批稿审阅；4187隔离临时服务在收口后停止。正式功能有独立red/green、领域/质量复审和适用门禁证据。

## 最终阶段观察

- 16:25:43 +08:00观察最终锁环境Flutter4002通过（3分05秒），完整仓库API/worker2788通过/84条件跳过/4失败（1784.73秒）。失败为1个已加载旧exporter与3个旧注册集合断言，最终worker/OpenAPI128通过（14.31秒）关闭；后续原脚本门禁exit0。不声称原完整脚本exit0，不重跑未变全API。
- 16:28:42观察Android standard Debug ARM64编译完成，Gradle128.5秒；0.4.6/2165版本未增，SHA c9f6efd8…，仅编译中间产物，不是固定签名重建交付。
- 16:34:08观察主工作区analyze无问题（27秒）；随后62项诊断/会话/账号交叉测试通过（8秒）。回填check/apply均0，原客户端14行诊断逐行匹配。各阶段累计工时未独立测量，不根据文件时间推算。
- 依赖预检曾阻止2个自动包升级，已恢复原锁并强制解析；最终全量与原生编译使用同一原锁环境。详情/原失败日志在验证报告。

## 最终交接

本任务源码回填完成，保留隔离工作树、分支与补丁供审查/回退，未提交/推送/部署/安装。正式catalog入口为本地4186 `?screen=profile-settings-default`，审批稿SHA不变。证据与实际解析包版本见 `source-identity.json`，源码编译元数据见 `android-compile-metadata.json`。iOS、真机、真实验证码待对应后续任务验收；现有生产和设备安装版本不含此次修改。
