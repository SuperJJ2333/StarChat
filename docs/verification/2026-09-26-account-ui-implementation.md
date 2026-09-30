# 账号与个人信息 UI 正式实施验证

日期：2026-09-26。用户批准 HTML 后明确“没有问题，请你正式实现”。实现基线 `b9eca8a419614112b085439445b7fd031027a740`，隔离分支 `codex/account-ui-implementation`。

## 实施范围

1. 个人信息去除字数计数，昵称和个性签名保持固定左标签，空值、编辑和保存后均保留。
2. 设置按“账号 / 通用”分组，账号安全提供手机、邮箱和密码入口；聊天页真实读写自动允许加入群聊偏好。
3. 登录“忘记密码”和账号安全共用双渠道验证码改密；服务端只接受当前已成功验证绑定的邮箱或手机号。
4. 邮箱绑定/换绑先证明原渠道，再验证新邮箱；手机复用现有换绑流程。新接口与 OpenAPI 同步，旧协议兼容。

对应 [批准设计](../superpowers/specs/2026-09-26-account-ui-review-design.md)、[实施计划](../superpowers/plans/2026-09-26-account-ui-implementation.md)、[ADR-0085](../adr/0085-account-credentials-and-otp-password-recovery.md)、[任务记录](../workflow/tasks/2026-09-26-account-ui-implementation.md)及 [OTP 运维说明](../runbooks/account-credentials-otp.md)。

## 候选与验证

证据目录：`docs/verification/artifacts/2026-09-26/account-ui-implementation/`。最终领域与独立质量/安全审查均通过；源码验证与生产发布分别记录。

| 检查 | 观察结果 | 证据 |
| --- | --- | --- |
| frontend 全量 | 316通过，exit0 | `frontend-evidence.json`及 frontend 日志 |
| Flutter / HTML 合同 | 33组件 / 447画面一致 | UI contract 日志 |
| 浏览器交互与视觉 | 10项通过；light/dark截图核对 | `catalog-browser-results.json`、`quality-frontend-review.md` |
| 后端安全与旧认证 focused | 71通过，exit0，41.12秒 | `backend-security-freeze-confirmed.log` |
| PostgreSQL 并发/过期/deadline | 9通过，exit0，10.71秒 | `backend-security-postgres.log` |
| API / worker 短信配置 | 2 RED → 2 GREEN；Compose render exit0 | `config-red.log`、`config-green.log` |
| OpenAPI 可选鉴权导出 | 1 RED → 5 GREEN，另8路由字段/鉴权核对 | `openapi-red.log`、`openapi-green.log`、`openapi-final.log` |
| 最终 Flutter 完整测试 | 4002通过，exit0，3分05秒；analyze无问题 | `flutter-full-final.log`、`flutter-analyze-final.log` |
| 最后 refresh / 会话生命周期回归 | 作者28项、父83项通过，exit0 | `flutter-refresh-lineage-green.log`、`flutter-lineage-regression.log` |
| Android ARM64 编译 | standard Debug，exit0，Gradle128.5秒 | `android-compile.log`、`android-compile-metadata.json` |
| Python移动边界 / 后续仓库门禁 | 108通过/1条件跳过；UI合同、import、268 AST、Alembic、OpenAPI、Compose通过 | `post-backend-gates.log`，exit0 |
| 主工作区回填与交叉回归 | analyze无问题；62项通过，exit0 | `original-analyze.log`、`original-integration-regression.log` |

完整 `scripts/verify.ps1` 已运行，政策、模板、render、infra146、Getui28、Matrix bot9通过；API/worker为2788通过/84条件跳过/4失败（1784.73秒），原完整脚本真实退出1。1处为进程在父修复前已加载旧 OpenAPI exporter；3处为旧 worker 注册集合没有包含新增账号事件处理器。最终 worker 全量与 OpenAPI 共 **128项通过 / exit0 / 14.31秒**，新增懒注册测试确认装配不会访问短信、邮件或SDK网络；4处失败全部关闭。日志为 `backend-final-delta-green.log`。后续门禁按原脚本逐项执行并已退出0，不把原脚本说成退出0；依照交付流程复用未变业务输入的完整运行证据，无重复30分钟全API运行。

HTML catalog 为固定393px审阅框；其窄浏览器截图不作为移动响应式证据。Flutter 已有320px与1.4倍文字测试。批准单文件 demo SHA 仍为 `b0a20fba79dcd11845fa57aabb52696c6606553167f80719cee063abeffce45e`。

## 审查修复与边界

先领域/规格，后独立质量/安全审查。修复投递未就绪挑战、旧渠道证明有效期、供应商耗时枚举、数据库锁后时间复查、迟到校验回滚、阻塞 Redis 和新投递路径异常脱敏；Flutter 修复重复 logout 清新会话、密码草稿过期残留和聊天偏好超时重复写入。

最初 Flutter 完整测试的7项失败已留存：1项登录链接夹具未滚动到可见位置，6项 Windows 长路径缓存夹具。相应夹具修正后完整通过；没有改动生产缓存行为。最初 analyzer 的26项花括号提示已按作用域修正，失败日志保留。

最后同 family refresh 竞态已用真实受控 HTTP 红绿测试关闭：固定出站 Bearer，仅可信刷新推进在途会话谱系；手工替换和新登录后迟到成功均保留新会话。对应领域及移动安全报告最终PASS。

普通 `pub get` 在原生预检时更新了 `image_picker_ios` 与 `octo_image`，锁一致性断言在编译前拦截。恢复基线锁后使用 `PUB_HOSTED_URL=https://pub.dev` 与 `flutter pub get --enforce-lockfile` 成功，最终4002完整测试与编译都使用该锁定环境；未交付依赖升级。解析后的包版本与源码身份一同记录。

编译中间 APK：`apps/mobile_flutter/build/app/outputs/flutter-apk/app-standard-debug.apk`（隔离工作树），151766805字节，SHA-256 `c9f6efd8671a9111661b62b67e8db0313ce3af60d351145754c48b596c1ccaa0`；`com.liuhetong.mobile`、0.4.6/2165、仅arm64-v8a、debuggable。它仅证明源码编译，不是按固定重建/签名流程交付的安装包。

现有环境警告已保留：Starlette httpx/Pydantic旧配置弃用提示，以及现有Flutter插件的未来KGP兼容提示和Java弃用/unchecked注释。本任务没有新增依赖或放宽构建检查，当前分析与编译通过；未来插件迁移不属于本UI改造。

无生产部署、真实邮件/短信发送、真实账号改动、设备安装或版本递增。原生构建仅作编译门禁，中间 APK 不作为正式交付安装包。iOS、真机和真实渠道验收另需相应环境与授权。Matrix 密钥、本地聊天历史及金融状态边界保持。

## 环境和交接

Windows10 build19045.6466；Flutter3.44.9 / Dart3.12.2；Python3.12.10；Node22.22.2；Docker29.2.1。Android SDK36与许可证可用；Android Studio JDK21。doctor 的PATH、Visual Studio及GitHub探测警告不代表Android编译结果。

本任务已安全回填 `D:/pythonProject/outsource/StarChat`。`git apply --check` / apply均exit0，再复制29个任务新文件；`BusinessApiClient`相对隔离候选只多出原有14行诊断代码，逐行完全匹配。其余既有诊断、头像、main、home及旧文档等修改保留；主工作区强制锁解析、完整analyze及62项诊断/会话/账号交叉回归均通过。没有提交、推送或清理其他任务工作树。

最终源/声明锁/实际解析包版本见 `source-identity.json`，回填身份见 `integration-result.json`、`retained-diagnostics.json`。前端/后端/移动独立审查报告、失败和重试日志均保留；保存的证据位于上述任务子目录，运行时测试数据库及浏览器配置不作为交付证据复制。

正式 HTML catalog 可从本地服务打开 `http://127.0.0.1:4186/?screen=profile-settings-default`。审批稿仍原样保存用于对比。当前源码验收完成；下一步若需安装包/发布，按移动交付与APK固定重建流程另行领取，使用新的版本及最终签名身份，不能分发本次编译中间APK。真实双渠道验证码和iOS/真机效果尚未实测，不以隔离测试代替该验收。
