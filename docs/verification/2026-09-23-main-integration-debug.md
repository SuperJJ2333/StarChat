# 2026-09-23 main 整合与 Mi6 Debug

## 整合结果

用户授权合并本地分支并安装新 Debug，未请求 Git 远端推送或再次部署服务器。

- 基线 main：0125d50a；原工作区修复先提交保存为快照，再正常三方合并 phone-wallet-live-compat、android-040-release-20260922。
- 777634ab 整合发布可靠性与最新手机/钱包修复；ded5eb0e 合入 Android040 最终发布记录；c7cff671 为新包来源提交。
- 所有原本地分支 tip 均为 main 祖先，无遗漏提交。删除5个未占用且完整合并的分支，以及 docs-consolidation、ios-distribution-2144 两个干净工作树及其分支。历史脏审查工作树及本地配置保留。
- ios-reboot-session 的 Git 工作树登记已清理，长路径构建残留目录删除失败，随后自动审批拦截删除操作；未强行清除残留。对应已合并分支仍保留。release-metadata-gates 未继续删除。
- 根目录历史截图移到本次工件目录；生成的 Gradle 缓存不再纳入 Git；本地 .zcode 计划保留并忽略。

## 规格与质量核对

先核对用户需求：手机注册/换绑、现有钱包充值提现 UI、参考汇率、取消充值、群转让状态和红包 UI 保留。再检查跨分支鉴权与生命周期：持久 refresh operation、设备键、终端会话失效分类、历史窗口与消息锚点全部合入；后台财务权威和 schema0083 未回退。

交叉缺陷：短信登录没有重置旧会话 refresh backoff；新增测试先以 SESSION_REFRESH_PENDING 失败，再对齐密码登录重置 retryAt/failure count，转绿。未降低鉴权或更改业务手续费规则。

整合后服务端、服务端测试、迁移与 OpenAPI 对 60238a4b 的 Git diff 为零，与刚验证并上线的后端完全一致。

## 验证记录

工件目录：docs/verification/artifacts/2026-09-23/main-integration-debug/。

| 项目 | 结果与证据 |
|---|---|
| Flutter 全量 | 3870 passed，exit0；flutter-full.log / flutter-exit.txt |
| Flutter analyze | 初次测试格式提示已修；最终 No issues found，exit0；analyze-final.log |
| 手机专项 | 10 passed，exit0；phone-refresh-green.log；red.log 保留合并缺陷复现 |
| frontend | 245 passed / 0 failed，exit0；frontend.log |
| 后端证据复用 | 2544 passed / 59 skipped，原 verify exit0；服务端和契约与已上线60238a4b完全相同，backend-parity.txt；原证据见2026-09-23-phone-wallet-live-restore.md |
| 本轮完整 verify | 启动后停止重复后端阶段，exit=-1；不能称此轮完整 PASS。Repository/Deployment/Template/Infra/Getui/MatrixBot已执行，后续项目由原脚本相同检查单独继续 |
| 后续影响检查 | exit0：mobile108 passed/1 skipped（783.44秒），UI32组件/398屏、import、AST254、Alembic0083单head/离线迁移、OpenAPI、Compose全部通过；verify-remainder.log |

全量后仅为新增测试 if 语句添加大括号，生产源码未变；补跑手机号专项和 analyze 通过。保留59个后端跳过项的未验证含义。未进行iOS新构建、500人压测或真实资金操作。

## 构建与真机

候选0.4.1+2159 Debug，com.liuhetong.mobile，ARM64；固定证书SHA256 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff。按源码构建→Apktool2.12.1完整重建→zipalign36→固定签名→独立验包执行。

Mi6安装前0.3.103+2158 Debug，证书匹配。2026-09-23T03:20:17+08:00已覆盖安装0.4.1+2159 Debug，install返回Success、版本读回一致、MainActivity启动Status: ok，应用进程存在。未卸载、未清数据。真实业务操作与视觉效果仍由用户验收。

最终APK：docs/verification/artifacts/2026-09-23/main-integration-debug/final.apk，145412395字节；SHA256 `573370bc936dfbebd9d50ba6d98a6a3efbd6b45aefbab965e55f3876fec9a382`。独立解包核对27317个类、339项原生库/资产全部一致，manifest语义一致；DEX与资源确实完成重建，apksigner/zipalign均通过。见verification.json、installed-verification.json、install.log、launch.log。

## 时间与后续

Flutter全量5分33秒；最终analyze14.6秒。整合调查早期时间未完整保留，不推算精确耗时。阶段时间以本次工具日志为准。下一步：用户在Mi6上复验会话切换、手机换绑、汇率与取消充值。此次约13分钟等待主要为历史工件敏感字面量扫描，最终未跳过该安全检查。所有本次启动测试与构建均已结束。
