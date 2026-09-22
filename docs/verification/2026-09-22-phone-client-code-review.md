# Flutter 手机号与充值契约层复审

## 结论

17 个新增方法的路由、HTTP 方法和主要载荷与后端及 OpenAPI 对齐，独立网关接口没有破坏既有邮箱注册替身。发现并修复两个客户端缺陷；原 7 项固定响应测试不足以证明持久化、弱网或真实服务端验收。

用户已确认短信服务验证完成，本轮不发码、不读真实凭据、不部署、不做 UI 或真实资金操作。短信既有成果不重复记为本轮新增验收。

## 修正

| 级别 | 缺陷 | 修正/证据 |
| --- | --- | --- |
| P1 | phoneLogin 没清理旧 Matrix grant 的 Retry-After 冷却；之前请求 429 后，新手机登录成功仍被本地拒绝进入聊天 | 新登录开始清理冷却，与密码登录一致；测试旧 429→新登录→新 Bearer 请求 grant 成功 |
| P2 | 五个公开手机号 HTTP 请求没有超时，弱网请求不完成时可无限等待 | 统一既有 8 秒预算；不自动重发，迟到成功不写入会话。五项 fakeAsync 挂起请求测试 |
| 验证缺口 | “会话持久化”测试没有读存储；MockClient 任意路由返回 200；换绑字段、隐私和取消缺覆盖 | 读取四个真实会话字段、登出后迟到响应、OTP_INVALID、Bearer、new_phone、PATCH/POST、设备键；所有原契约用例对照生成 OpenAPI 校验路径/方法/必需字段/额外字段与基础约束 |

未改变权限、OTP 次数、后台状态机、金额精度、财务规则或加密协议。受保护认证修正记入 ADR-0075；独立审查先规格再质量，无额外客户端路由/安全阻断。

## 验证与基线

隔离工作树 `.worktrees/phone-client-audit`，分支 `codex/phone-client-audit-20260922`。153 项相关输入及基线 HEAD/时间见 [input-snapshot.json](artifacts/2026-09-22/phone-client-audit/input-snapshot.json)。主工作区差量回填前核对哈希，保留其他任务修改。

- 修复前新增 8 项：2 passed / 6 failed（冷却 + 五个无限等待）；红灯见 red.log。
- 最终专项 17 passed（final-focused.log）。首轮转绿时测试回调返回类型不符导致 5 项测试自身报错，已修正，原 green-first-failed.log 保留。
- Flutter 全量：3702 passed，exit 0（flutter-full.log、flutter-exit.txt）；生产代码在整轮保持不变。期间修正测试的三个 lint 信息，之后再跑最终 17 项；无行为变化，不重复全量。
- flutter analyze --no-pub：No issues found（analyze.log），初次三项 lint 记录保留。
- Python infra + mobile：228 passed，exit 0（boundary.log）。仓库/部署策略、模板与配置渲染、UI 漂移（32 components/375 screens）、OpenAPI、Compose 通过（impact-gates.log）。
- 按移动交付工作流的影响分析复用上轮完整 verify：服务端、对应测试、依赖锁、契约和脚本等 639 个文件字节相同，差异 0（backend-evidence-reuse.json），且后端测试不引用本次 Flutter 文件。上一轮后端 2449 passed/58 skipped、verify exit 0 的结果仍为同输入证据。**本轮没有重新运行整套 verify.ps1，不将复用写成新跑通过**；58 skipped 仍未验证。

工具 Flutter 3.44.9 / Dart 3.12.2 / Python 3.12，沿用原 pubspec.lock。初次离线 pub get 受主机镜像变量影响重写来源并挑选不同 record_linux 版本，已在执行有效测试前恢复原锁、使用 pub.dev 缓存与 --offline --enforce-lockfile 成功；之后均 --no-pub，无依赖更新或网络下载。最初两次测试启动受脚本路径/锁一致性检查阻断，未算业务失败；真正红灯来自最终修正后的夹具。

## 明确限制与下一步

- 短信供应商验收已由用户确认；本轮无新短信、无真实后端/真机端到端链路。
- 注册验证接口当前忽略客户端幂等键，已消费 OTP 的成功响应丢失后重试可能失败；充值取消重复请求可能 409。属于既有服务端限制，已写入客户端接口注释。UI 必须先用注册状态/我的申请查询恢复，不能宣称附带键就能自动重放。
- Flutter 页面、Controller、状态恢复交互、demo/registry 同步、Android/iOS 真机仍未实施。按[已更新下一步 prompt](../workflow/prompts/2026-09-22-zcode-after-third-review.md)继续独立 UI 批次。
- 转让开关仍关闭，未提交/发布；没有打 APK/IPA。

修正文件与回填前后 SHA 见 [applied-changes.json](artifacts/2026-09-22/phone-client-audit/applied-changes.json)，最终输入见 [final-inputs.json](artifacts/2026-09-22/phone-client-audit/final-inputs.json)。
