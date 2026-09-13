# 财务修复 main / 生产 / Mi 6 2106 交付

2026-09-13 14:08+08:00 完成运行验收。用户授权合入 main、部署并安装到 Mi 6；Astra 主审并执行发布/安装，两个明确指定 gpt-5.6-terra 的执行代理分别处理 scratch 合并及发布工具、Android 构建工具。真机功能由用户测试。

## 实际交付

- 修复提交 `e911f7c23022eede40d146bdee8e27abd1467fad` 已快进合入 main，并推送 origin/main。43 个修复文件；主工作区其他任务的 126 个文件在集成写入时逐项验证保留。重叠文件三方合并，未回退或提交其他任务修改。
- 本地完整候选包含 main 原有钱包/客服等未提交改动，保留用户当前工作状态；不能把完整 APK 描述成仅凭干净 `e911f7c2` 可复现。构建输入哈希、原始依赖锁身份记录在下述证据目录，未将未审查后台整树发布。
- API 从 `119e69710767af56613425341ed7e7920f5f1d9123d3926c8ee0139dd159ce1f` 增量发布到 `dc41eb54a82cd1e7f9717043ba87d19e8d5f1c36381a8b923b36ae984be72f90`，仅覆盖 ledger API、main 注入、profile 公开名称读取和 statements 投影四个文件。环境和 HostConfig 相等，其余容器 ID 未改变，无新运行 Traceback。
- schema 保持 `0066_manual_deposit_cases`，无迁移、无生产资金操作。保留个推、E2EE、客服与人工补录功能。未更改正式 Android/iOS 更新设置或发布 HTML 设计演示页。
- Mi 6 `cbd0156b` 的 `com.liuhetong.mobile` 已从 **0.3.87-debug/2105** 保留数据覆盖安装到 **0.3.88-debug/2106**。ADB 返回 Success，读取已安装版本并拉回 APK 哈希一致；未卸载、未清除数据、未执行用户功能测试。

## APK 身份

最终文件：`artifacts/2026-09-13/finance-six-release/android-0.3.88-debug-2106-same-package/ChatFlow-0.3.88-debug-2106-arm64-rebuilt.apk`。

- SHA256：`3e473baaaa71f94ed5f929e9d7f7277c225bd6ee0673612bc09b529654ceacc5`
- 固定证书 SHA256：`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`
- 源 APK SHA256：`a2ffe7f78020bf503d425f206dc25c9c926adb744bffb32a0da9f44419534671`
- ARM64/debug；Apktool 2.12.1、build-tools 36.0.0、固定签名。源与重建包 336 个原生/Flutter 资产条目 SHA 相同；27,313 个 smali 类严格类型默认值规范化后相同；清单语义相同，zipalign 与 apksigner 通过。
- 构建明确传入三项原有 HTTPS LIUHETONG dart-define，以及 `--android-project-arg chatflowParallelDebug=false`。未更改全局 Gradle 配置。

## 本轮验证

所有日志位于 `artifacts/2026-09-13/finance-six-release/`。

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| flutter test --no-pub --reporter expanded | 2524 passed / 0 failed，122 秒 | flutter-full.log |
| flutter analyze --no-pub | No issues found，19.2 秒 | flutter-analyze.log |
| npm test | 207 passed / 0 failed | frontend-full.log |
| 账单/客服/人工补录兼容/API合约 + mobile | 97 passed，143.12 秒 | api-mobile-integration.log |
| OpenAPI / UI contract | PASS；30 components / 368 screens | 执行输出与 task 记录 |
| 发布脚本验证 | Terra 6 项及 Astra 3 项故障注入通过 | test_server_release.py、astra-actuator-tests.log |
| 实际候选 Linux 账单套件 | 17 passed；两轮同镜像，最终 5.68 秒 | production-r2-prepare-tests.log |
| Compose 配置 | 有效配置仅 API image 变化 | production-r2-prepare-tests.log |
| 生产切换与源码读回 | 4 文件 SHA、schema、环境/HostConfig、其他容器通过 | production-postcheck.log |
| 两侧 HTTPS | JSON ok=true / database=ready；匿名真实账单路由401，TLS验证保留 | production-postcheck.log、workstation-public-check.json |
| Mi 6 | install Success、2106/0.3.88-debug，拉回SHA相等 | mi6-install.log、mi6-version.txt、mi6-installed-2106.apk |

沿用前轮未变输入的仓库/部署/infra/个推/Matrix/业务长门禁证据，不重复宣称旧整条 verify 全绿。本轮集成后的移动端和前端全量已清零此前报告的 29/11 项失败。

最终工作区核对发现另一个任务继续修改了 admin-wallet-access.js、其测试、admin-ui-production 计划/记录及 current-state 索引，共5个非本任务文件；本任务未覆盖这些变化。207项前端结果对应本轮运行时的集成输入，不冒充这些后续外部变化的测试结果；它们未纳入此次4文件API发布或APK源码。

## 返工与回退记录

1. 首次源码编译后锁文件字节检查拒绝继续。主代理重建并核对构建前 SHA，证明只有 217 个 hosted URL 从 pub.dev 改为镜像，包版本/内容哈希未变；已恢复原锁文件完整字节（SHA `438497b045eff8ea71413d1cd94e88d0e95d945fad2267b94db114c738b1a5d1`）。早先执行代理与错误工作树比较得出的“版本升级”判断已纠正。
2. 首份重建包的包名检查拒绝安装：本机用户级 Gradle 设置 `chatflowParallelDebug=true` 生成 `.debug` 包。显式构建参数覆盖后重新构建到独立目录；错误包未安装，没有修改 manifest 绕过包名检查。
3. 生产 r1 验收脚本误用不存在的 `/ledger/statements`，收到404后自动回退到 `119e6971`。切换/回退期间短暂观测到502，原服务健康恢复后确认真实路由 `/ledger/transactions/me` 为401，再以独立 r2 发布目录重做候选检查并成功切换。r1 日志和备份保留，不把首次发布说成成功。
4. r2 启动等待期间首次本机连接被拒绝，重试后通过；这是检查进程的启动等待输出。最终应用容器 Traceback 计数为0。

有效回退目录：服务器 `/opt/starchat/releases/finance-six-20260913-r2/`（0700）。`python3 .../server_release.py rollback` 仅允许已知当前候选或基线镜像，恢复 `119e6971` 和冻结运行配置，保留数据库及审计。r1 回退已经实际执行成功；r2 当前保持新镜像。敏感运行配置及备份仅留服务器。

## 时间与待用户验证

首次采样 13:35:35+08:00，公网最终验收 14:08:22+08:00，约33分钟墙钟；集成/验证与构建/生产准备有并行，不相加。编译、包名与发布检查返工均保留独立日志。

用户可在 Mi 6 验证金额对齐、备注昵称更新、账单详情、群转账/专属红包头像以及三次拍一拍后 toast。限频仍是进程内每用户每房间滚动60秒配额，杀进程/跨设备不共享；未声称实现服务端全局防绕过。真实资金、跨端和微信手感由用户继续验收。
