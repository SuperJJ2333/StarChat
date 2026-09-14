# docs 整理、归档与删除执行记录

日期：2026-09-10。用户已审核[清单](2026-09-10-docs-cleanup-review.md)并明确批准执行；依据[计划](../superpowers/plans/2026-09-10-docs-cleanup-execution.md)。

状态：已完成本次审核范围内的整理。89/89 个生成目录已归档并删除散文件；原始/保全资料与恢复测试例外按下文保留。没有部署、推送或修改产品代码。

## 文档治理

- 新增 docs、runbooks、plans、figma 的导航；保留历史文件原址及事实。
- 将 `docs/ME.md` 的工作目录与非交互命令合并到激活码 runbook，修正默认 SSH jumper 后删除旧文件。181 字节原文归档，SHA256 `2dda3461456dfec197122a2161be3b7cea4777cd73d0398221a81bc45e0de7d7`。
- Figma 旧流程标记 Retired，冻结历史台账；当前 HTML 流程明确上级命名规则，不改写旧节点“未同步”事实。
- 发布入口区分现行打包/部署规则和旧 CI 限制；mobile-release 的 Android 示例改为 ARM64，并补齐 Getui HTTPS 参数。
- 明确保留策略的默认期限、提前审批、逐文件归档门禁、永久审计证据和本地备份边界。

## 工件管理

- 2026-09-10 之前的历史生成目录按[精确候选清单](artifacts/2026-09-10/docs-audit/cleanup-candidates.json)处理。候选统计为 89 个路径、约 26.23 GiB；实际结果以事件日志为准。
- 每个目录先无损 ZIP（含空目录），逐成员读回验证 SHA256，再完整核对源文件哈希、metadata 与活动进程。只有成功后才执行原生 PowerShell `Remove-Item -LiteralPath`。
- [本地归档与恢复说明](archives/2026-09-10-docs-cleanup/README.md)；[操作事件](artifacts/2026-09-10/docs-audit/cleanup-events.jsonl)。归档保留所有字节，继承原证据保留级别，不是异地备份。
- 原始用户 APK 已迁移到 `archives/2026-09-10-docs-cleanup/samples/modifier-0.3.38/`，移动前后 SHA256 一致；原分析报告已补充新的归档链接。
- branch-consolidation 既有备份原址登记长期归档：10 ZIP + 3 bundle 均重新核对 SHA256；三个 bundle 另通过 `git bundle verify`。保留未提交工作与已删除 worktree 的恢复资料，不删除任何唯一备份。
- plain36 / nomin36 的两个实验 APK 与两个源码 ZIP 已移入样本归档，四次移动均核验前后 SHA256；原 README、签名/清单/日志留在原址，并补归档入口。
- 审核 D07/D08 已增加两份无损保全归档：`public-apk-audit-1`（567 文件）和 `admin-modernization/MODIFIED_FILE`（399 文件）。ZIP 每个成员与原目录哈希一致；这两处属于历史审计/恢复资料，原路径也保留，不计入 89 个生成目录删除量。[快照索引](archives/2026-09-10-docs-cleanup/preserved-snapshots.json)。
- 当日交付目录、原始源码、最终发布包、签名工具、部署/回滚脚本、财务/E2EE正文均保留。未满期限的截图不按文件名自动删。

## 验证与审查

- 归档保护测试先得到缺失实现的失败，再实现并通过 5 项测试：越界/当天目录拒绝、手改字节和空目录保留、源变化拒绝、压缩包损坏拒绝、新增文件拒绝。调整流式 ZIP 写入后 5 项再次通过。
- 独立规格审查先于质量/安全审查；补强删除前父路径活动检查与最终 metadata 复核后复审通过。
- 一份真实 Gradle 归档已实际恢复到新的具名目录，14 文件、22,056,229 字节全部验证：[恢复证据](artifacts/2026-09-10/docs-audit/restore-check-result.json)。
- 文档实现检查 102 个链接，独立复审检查 88 个链接，均通过；历史审计/Figma正文保留。`python scripts/verify_ui_contract.py` → PASS（22 components, 332 screens）。
- 没有产品行为变更，不运行无关产品构建/部署；不声称全仓产品测试通过。

## CodeGraph 检索治理

- 根 `codegraph.json` 使用安装版 1.6.0 支持的 `exclude` / `include`；不是未支持的 `.codegraphignore`。
- 10 条排除规则限定 verification 内生成目录、plain36/nomin36 的源码副本和 archives，未整体排除 verification。
- 首次同步核验发现现有 Git 忽略规则使发布工具漏入索引，已用 4 条精确 include 白名单修正；没有放开 Git ignore 或暴露工件。
- 重新同步及实际索引检查通过：verification 索引 198 文件，排除路径 0；27 个白名单 Python 脚本均可索引，`server_release.py` 已在索引中。安装版不支持 PowerShell，签名 `.ps1` 保留原址，不宣称已被索引。
- [实际索引核验](artifacts/2026-09-10/docs-audit/codegraph-scope-result.json)。未删除索引数据库、未终止已有 daemon。

## 保留项与限制

- 自动审批拒绝了删除恢复测试副本的操作，仅返回 `blocked by policy`。没有重试或改用其他删除方式；约 21 MiB 测试副本保留在 `artifacts/2026-09-10/docs-audit/restore-check/nomin36-gradle/`。
- 旧发布脚本自身未改写，仅纠正文档适用范围；聊天 UX 历史待做仍需独立功能验收。
- 当前工作区有其他任务正在修改 `2026-09-10-platform-release-2085.md` 等文件，本任务不覆盖其内容。磁盘空间统计以清理账目为主，不将其他任务的磁盘变化归功于本次清理。

## 最终结果

| 项目 | 结果 |
|---|---:|
| 已处理目录 | 89 / 89 |
| 已归档并删除的散文件 | 1,728,468 |
| 原散文件逻辑大小 | 27.23 GiB |
| 89 份 ZIP | 8.93 GiB |
| 89 份逐文件清单 | 335.18 MiB |
| 新增两处保全快照及索引 | 131.08 MiB |
| 因审批拦截保留的恢复测试副本 | 21.03 MiB |
| 净减少（扣除上述大项） | 约 17.82 GiB |
| 整理后 docs 实时快照 | 601,391 文件 / 53.65 GiB |

空间采用文件逻辑字节数核算，不是 NTFS 实际释放块数；净值未扣除少量新增脚本/报告/目录索引（不足以影响上述两位小数）。整理前后其他任务仍有写入，因此不把整个 D 盘空闲变化作为本任务成绩。原始候选 26.23 GiB 是按名称分类的扫描桶，最终数值按每个完整目录的实际清单统计，包含原扫描分到嵌套分类的文件。

三个临时 active-process 跳过项均已由另一处理批次完成；最终按路径去重后无未处理候选、无缺失归档、无原目录重新出现。没有通过重试绕过恢复测试副本的审批拒绝。

最终重新读取 89 ZIP 的 SHA256，并检查 manifest 的来源/字节数/文件数与删除记录一致；另核验 2 保全归档和 5 迁移工件；22 份文档中的 215 个本地链接通过。见[最终验证结果](artifacts/2026-09-10/docs-audit/final-verification.json)、[空间账目](artifacts/2026-09-10/docs-audit/space-accounting.json)、[逐文件归档索引](archives/2026-09-10-docs-cleanup/catalog.json)。

### 逐目录完成清单

以下每行的原散文件目录均已删除，完整内容位于对应 ZIP，恢复步骤见归档 README。列出的大小是原散文件大小，不是该行可释放空间。

| 原路径 | 文件数 | 原 MiB | ZIP MiB | 完整 manifest |
|---|---:|---:|---:|---|
| `docs/verification/artifacts/2026-09-05/apk-rebuild-test/decoded` | 26,216 | 278.74 | 86.51 | [记录](archives/2026-09-10-docs-cleanup/fec18aaa658bbb6ba34e.json) |
| `docs/verification/artifacts/2026-09-05/apk-rebuild-test/verified-decoded` | 25,666 | 250.64 | 73.99 | [记录](archives/2026-09-10-docs-cleanup/bfa46718ed21293aba27.json) |
| `docs/verification/artifacts/2026-09-05/incoming-call-permission-dedup/rebuild-0341/decoded` | 26,216 | 278.76 | 86.52 | [记录](archives/2026-09-10-docs-cleanup/026d9c9998c83494bceb.json) |
| `docs/verification/artifacts/2026-09-05/incoming-call-permission-dedup/rebuild-0341/verified-decoded` | 25,666 | 250.64 | 73.99 | [记录](archives/2026-09-10-docs-cleanup/e5f199b259f48b3491c6.json) |
| `docs/verification/artifacts/2026-09-06/mi6-production-debug/package/decoded` | 26,577 | 459.65 | 142.16 | [记录](archives/2026-09-10-docs-cleanup/d3d8175380ba434ef43f.json) |
| `docs/verification/artifacts/2026-09-06/mi6-production-debug/package/verified-decoded` | 26,007 | 426.29 | 127.35 | [记录](archives/2026-09-10-docs-cleanup/1f92be15e776567d539c.json) |
| `docs/verification/artifacts/2026-09-06/push-cold-start/rebuild-0342/decoded` | 26,219 | 278.78 | 86.52 | [记录](archives/2026-09-10-docs-cleanup/b09f8dbe37c773f7085e.json) |
| `docs/verification/artifacts/2026-09-06/push-cold-start/rebuild-0342/verified-decoded` | 25,669 | 250.66 | 74.00 | [记录](archives/2026-09-10-docs-cleanup/69027b9e29926b6a5cb4.json) |
| `docs/verification/artifacts/2026-09-06/v0.3.45-release/decoded` | 26,241 | 322.95 | 108.60 | [记录](archives/2026-09-10-docs-cleanup/4222bd7b12cf2c674f5c.json) |
| `docs/verification/artifacts/2026-09-06/wallet-application-mi6/mi6/decoded` | 26,219 | 271.96 | 83.51 | [记录](archives/2026-09-10-docs-cleanup/6d65c81eff9dc09d9b7d.json) |
| `docs/verification/artifacts/2026-09-06/wallet-application-mi6/mi6/verified-decoded` | 25,669 | 243.84 | 70.99 | [记录](archives/2026-09-10-docs-cleanup/b9243a9fe268c5df280e.json) |
| `docs/verification/artifacts/2026-09-06/wallet-application-mi6/standard-final/decoded` | 26,219 | 279.41 | 86.94 | [记录](archives/2026-09-10-docs-cleanup/9426820cb70211f26b37.json) |
| `docs/verification/artifacts/2026-09-06/wallet-application-mi6/standard-final/verified-decoded` | 25,669 | 251.29 | 74.41 | [记录](archives/2026-09-10-docs-cleanup/d5db7dd06644b34845f9.json) |
| `docs/verification/artifacts/2026-09-06/wallet-application-mi6/standard/decoded` | 26,219 | 279.41 | 86.94 | [记录](archives/2026-09-10-docs-cleanup/3da5857691f273d5494a.json) |
| `docs/verification/artifacts/2026-09-06/wallet-application-mi6/standard/verified-decoded` | 25,669 | 251.29 | 74.41 | [记录](archives/2026-09-10-docs-cleanup/1cfabed2ec7f9c5b7bcf.json) |
| `docs/verification/artifacts/2026-09-07/friend-release-integration/package/decoded` | 26,219 | 279.47 | 86.97 | [记录](archives/2026-09-10-docs-cleanup/104d3a3f0386bee62903.json) |
| `docs/verification/artifacts/2026-09-07/friend-release-integration/package/verified-decoded` | 25,669 | 251.35 | 74.44 | [记录](archives/2026-09-10-docs-cleanup/2c67ec88835d081dd253.json) |
| `docs/verification/artifacts/2026-09-07/ios-device-logs/venv/Lib/site-packages/IPython/core/__pycache__` | 51 | 1.10 | 0.54 | [记录](archives/2026-09-10-docs-cleanup/bede34b5b6cbd63fc934.json) |
| `docs/verification/artifacts/2026-09-07/ios-device-logs/venv/Lib/site-packages/PIL/__pycache__` | 97 | 1.32 | 0.66 | [记录](archives/2026-09-10-docs-cleanup/0a3f156838ccfcaff7a8.json) |
| `docs/verification/artifacts/2026-09-07/ios-device-logs/venv/Lib/site-packages/pip/_vendor/rich/__pycache__` | 77 | 1.08 | 0.51 | [记录](archives/2026-09-10-docs-cleanup/e4f3d9a9aff9de0f9846.json) |
| `docs/verification/artifacts/2026-09-07/ios-device-logs/venv/Lib/site-packages/pygments/lexers/__pycache__` | 263 | 3.21 | 1.62 | [记录](archives/2026-09-10-docs-cleanup/dd586a469458fa7b8a2f.json) |
| `docs/verification/artifacts/2026-09-07/ios-device-logs/venv/Lib/site-packages/rich/__pycache__` | 77 | 1.12 | 0.53 | [记录](archives/2026-09-10-docs-cleanup/39c7e39a1457c3c9603c.json) |
| `docs/verification/artifacts/2026-09-07/ios-device-logs/venv/Lib/site-packages/wcwidth/table_grapheme_overrides/__pycache__` | 21 | 2.27 | 0.62 | [记录](archives/2026-09-10-docs-cleanup/abdae5b3ca70ff22d05c.json) |
| `docs/verification/artifacts/2026-09-07/ios-device-logs/venv/Lib/site-packages/win32/lib/__pycache__` | 33 | 1.07 | 0.44 | [记录](archives/2026-09-10-docs-cleanup/1abe4e5e6e4c0c16776b.json) |
| `docs/verification/artifacts/2026-09-07/ios-device-logs/venv/Lib/site-packages/xonsh/__pycache__` | 36 | 2.03 | 0.64 | [记录](archives/2026-09-10-docs-cleanup/4474258e4ad6f44f249a.json) |
| `docs/verification/artifacts/2026-09-07/manual-tron-completion/apk-2058/decoded` | 26,577 | 459.90 | 142.27 | [记录](archives/2026-09-10-docs-cleanup/db393fd1f4e67f908c11.json) |
| `docs/verification/artifacts/2026-09-07/manual-tron-completion/apk-2058/verified-decoded` | 26,007 | 426.54 | 127.45 | [记录](archives/2026-09-10-docs-cleanup/551c282dbefa87de5ecb.json) |
| `docs/verification/artifacts/2026-09-07/manual-tron-completion/apk-2059/decoded` | 26,577 | 459.90 | 142.27 | [记录](archives/2026-09-10-docs-cleanup/70771b1817f8a65c93bd.json) |
| `docs/verification/artifacts/2026-09-07/manual-tron-completion/apk-2059/verified-decoded` | 26,007 | 426.54 | 127.45 | [记录](archives/2026-09-10-docs-cleanup/a426e289c2c3b077082e.json) |
| `docs/verification/artifacts/2026-09-07/manual-tron-completion/apk/decoded` | 26,577 | 459.89 | 142.27 | [记录](archives/2026-09-10-docs-cleanup/bb90d420f0fbce4fe91f.json) |
| `docs/verification/artifacts/2026-09-07/manual-tron-completion/apk/verified-decoded` | 26,007 | 426.54 | 127.45 | [记录](archives/2026-09-10-docs-cleanup/7102fa49797850ce5a90.json) |
| `docs/verification/artifacts/2026-09-07/official-address-fix/apk/decoded` | 26,577 | 459.79 | 142.23 | [记录](archives/2026-09-10-docs-cleanup/1628a232e6796a3739c7.json) |
| `docs/verification/artifacts/2026-09-07/official-address-fix/apk/verified-decoded` | 26,007 | 426.44 | 127.41 | [记录](archives/2026-09-10-docs-cleanup/cf4610a16d45afb4c384.json) |
| `docs/verification/artifacts/2026-09-07/official-wallet-update/package/decoded` | 26,219 | 279.41 | 86.94 | [记录](archives/2026-09-10-docs-cleanup/4200c6d1153a91b92dc2.json) |
| `docs/verification/artifacts/2026-09-07/official-wallet-update/package/verified-decoded` | 25,669 | 251.29 | 74.41 | [记录](archives/2026-09-10-docs-cleanup/ce4ab77e61a6f8f30e6d.json) |
| `docs/verification/artifacts/2026-09-07/sender-order-debug/decoded` | 26,577 | 459.77 | 142.22 | [记录](archives/2026-09-10-docs-cleanup/33afb379ae232bee378d.json) |
| `docs/verification/artifacts/2026-09-07/sender-order-debug/verified-decoded` | 26,007 | 426.42 | 127.40 | [记录](archives/2026-09-10-docs-cleanup/7e2a82a5556c66acba07.json) |
| `docs/verification/artifacts/2026-09-07/wallet-binding-production/tronweb-vector/node_modules` | 3,553 | 34.80 | 10.85 | [记录](archives/2026-09-10-docs-cleanup/0b736fcc7ccdb4ffac58.json) |
| `docs/verification/artifacts/2026-09-07/wallet-debug-mi6/decoded` | 26,577 | 459.77 | 142.22 | [记录](archives/2026-09-10-docs-cleanup/255d47d0b732ce70353d.json) |
| `docs/verification/artifacts/2026-09-07/wallet-debug-mi6/verified-decoded` | 26,007 | 426.42 | 127.40 | [记录](archives/2026-09-10-docs-cleanup/34bbbf44eb4e99c3d1c9.json) |
| `docs/verification/artifacts/2026-09-08/address-wallet-wechat/decoded` | 26,577 | 459.95 | 142.29 | [记录](archives/2026-09-10-docs-cleanup/7528ed496da1fc8c8918.json) |
| `docs/verification/artifacts/2026-09-08/address-wallet-wechat/final-build/decoded` | 26,577 | 459.96 | 142.29 | [记录](archives/2026-09-10-docs-cleanup/fad0fa2f8992b1e73041.json) |
| `docs/verification/artifacts/2026-09-08/address-wallet-wechat/final-build/verified-decoded` | 26,007 | 426.60 | 127.47 | [记录](archives/2026-09-10-docs-cleanup/e8f6f1bdef3cc422df50.json) |
| `docs/verification/artifacts/2026-09-08/address-wallet-wechat/verified-decoded` | 26,007 | 426.60 | 127.47 | [记录](archives/2026-09-10-docs-cleanup/7e1bb94a0c16d308b92f.json) |
| `docs/verification/artifacts/2026-09-08/image-layout-mi6/decoded` | 26,577 | 459.90 | 142.28 | [记录](archives/2026-09-10-docs-cleanup/3948daabce18e45e6346.json) |
| `docs/verification/artifacts/2026-09-08/image-layout-mi6/verified-decoded` | 26,007 | 426.55 | 127.46 | [记录](archives/2026-09-10-docs-cleanup/46b93eee749c017fcc4b.json) |
| `docs/verification/artifacts/2026-09-08/ios-0353/android-companion/package-final/decoded` | 26,219 | 279.57 | 86.99 | [记录](archives/2026-09-10-docs-cleanup/bdb27cf27f66c8505582.json) |
| `docs/verification/artifacts/2026-09-08/ios-0353/android-companion/package-final/verified-decoded` | 25,669 | 251.45 | 74.47 | [记录](archives/2026-09-10-docs-cleanup/66336273b298002e878a.json) |
| `docs/verification/artifacts/2026-09-08/ios-0353/android-companion/package/decoded` | 26,219 | 279.57 | 86.99 | [记录](archives/2026-09-10-docs-cleanup/4f4e6a72bd2e2505b551.json) |
| `docs/verification/artifacts/2026-09-08/ios-0353/android-companion/package/verified-decoded` | 25,669 | 251.45 | 74.47 | [记录](archives/2026-09-10-docs-cleanup/1422b17a7e2525165d29.json) |
| `docs/verification/artifacts/2026-09-08/ios-0353/gateway-venv/Lib/site-packages/_pytest/__pycache__` | 46 | 1.01 | 0.49 | [记录](archives/2026-09-10-docs-cleanup/730e9e0f7fb972d8ecaa.json) |
| `docs/verification/artifacts/2026-09-08/ios-0353/gateway-venv/Lib/site-packages/pip/_vendor/rich/__pycache__` | 77 | 1.08 | 0.51 | [记录](archives/2026-09-10-docs-cleanup/b223a142691a00c9f221.json) |
| `docs/verification/artifacts/2026-09-08/ios-0353/gateway-venv/Lib/site-packages/pygments/lexers/__pycache__` | 263 | 3.21 | 1.62 | [记录](archives/2026-09-10-docs-cleanup/bad3951a986165709ff4.json) |
| `docs/verification/artifacts/2026-09-08/ios-0353/source/apps/mobile_flutter/.dart_tool` | 43 | 96.66 | 34.39 | [记录](archives/2026-09-10-docs-cleanup/7a65fff4b42999704328.json) |
| `docs/verification/artifacts/2026-09-08/ios-0353/source/apps/mobile_flutter/android/.gradle` | 14 | 23.24 | 4.63 | [记录](archives/2026-09-10-docs-cleanup/9444cc0154350cc242a5.json) |
| `docs/verification/artifacts/2026-09-08/ios-0353/source/apps/mobile_flutter/build` | 6,662 | 1124.71 | 509.48 | [记录](archives/2026-09-10-docs-cleanup/067f493b17ccc1e8fcf4.json) |
| `docs/verification/artifacts/2026-09-08/official-chat-update/package-final/decoded` | 26,219 | 279.51 | 86.98 | [记录](archives/2026-09-10-docs-cleanup/20dcbc00ed2510a33c2c.json) |
| `docs/verification/artifacts/2026-09-08/official-chat-update/package-final/verified-decoded` | 25,669 | 251.39 | 74.45 | [记录](archives/2026-09-10-docs-cleanup/609ad709ea0e0aee1d76.json) |
| `docs/verification/artifacts/2026-09-08/official-chat-update/package/decoded` | 26,219 | 279.50 | 86.98 | [记录](archives/2026-09-10-docs-cleanup/c07e36593e71a56eb2b5.json) |
| `docs/verification/artifacts/2026-09-08/official-chat-update/package/verified-decoded` | 25,669 | 251.39 | 74.45 | [记录](archives/2026-09-10-docs-cleanup/25f5067e06438958774e.json) |
| `docs/verification/artifacts/2026-09-08/wallet-activation-address/release/package/decoded` | 26,219 | 279.57 | 86.99 | [记录](archives/2026-09-10-docs-cleanup/1c0f017db707455f3600.json) |
| `docs/verification/artifacts/2026-09-08/wallet-activation-address/release/package/verified-decoded` | 25,669 | 251.45 | 74.46 | [记录](archives/2026-09-10-docs-cleanup/d0a12c77eb007f70f0fe.json) |
| `docs/verification/artifacts/2026-09-08/wallet-binding-guidance/decoded` | 26,577 | 459.95 | 142.29 | [记录](archives/2026-09-10-docs-cleanup/67fc143cefcd0007b8ca.json) |
| `docs/verification/artifacts/2026-09-08/wallet-binding-guidance/verified-decoded` | 26,007 | 426.60 | 127.47 | [记录](archives/2026-09-10-docs-cleanup/f0b1e07774e4d280ff22.json) |
| `docs/verification/artifacts/2026-09-08/wallet-compact/decoded` | 26,577 | 459.95 | 142.29 | [记录](archives/2026-09-10-docs-cleanup/45aedcbbf3bc94404418.json) |
| `docs/verification/artifacts/2026-09-08/wallet-compact/final-build/decoded` | 26,577 | 459.96 | 142.29 | [记录](archives/2026-09-10-docs-cleanup/6049dcf178e38377b084.json) |
| `docs/verification/artifacts/2026-09-08/wallet-compact/final-build/verified-decoded` | 26,007 | 426.61 | 127.48 | [记录](archives/2026-09-10-docs-cleanup/8d6095aca26692351c42.json) |
| `docs/verification/artifacts/2026-09-08/wallet-compact/rows-build/decoded` | 26,577 | 459.97 | 142.30 | [记录](archives/2026-09-10-docs-cleanup/416061e5f8433d62741c.json) |
| `docs/verification/artifacts/2026-09-08/wallet-compact/rows-build/verified-decoded` | 26,007 | 426.62 | 127.48 | [记录](archives/2026-09-10-docs-cleanup/4d85163de21d2b51dd95.json) |
| `docs/verification/artifacts/2026-09-08/wallet-compact/status-build/decoded` | 26,577 | 459.96 | 142.29 | [记录](archives/2026-09-10-docs-cleanup/76915375f1058db3e30a.json) |
| `docs/verification/artifacts/2026-09-08/wallet-compact/status-build/verified-decoded` | 26,007 | 426.61 | 127.48 | [记录](archives/2026-09-10-docs-cleanup/412f81563841a8a99a4b.json) |
| `docs/verification/artifacts/2026-09-08/wallet-compact/verified-decoded` | 26,007 | 426.61 | 127.48 | [记录](archives/2026-09-10-docs-cleanup/71a86546d48b9b5603df.json) |
| `docs/verification/artifacts/2026-09-08/wallet-independent-activation/client/package/decoded` | 26,219 | 279.64 | 87.01 | [记录](archives/2026-09-10-docs-cleanup/f36ead2338a0a65068f3.json) |
| `docs/verification/artifacts/2026-09-08/wallet-independent-activation/client/package/verified-decoded` | 25,669 | 251.51 | 74.49 | [记录](archives/2026-09-10-docs-cleanup/e772050d9b5b46de8834.json) |
| `docs/verification/artifacts/2026-09-08/wallet-independent-activation/client/source/apps/mobile_flutter/.dart_tool` | 43 | 96.79 | 34.42 | [记录](archives/2026-09-10-docs-cleanup/a75f746b9c3f34e9269a.json) |
| `docs/verification/artifacts/2026-09-08/wallet-independent-activation/client/source/apps/mobile_flutter/android/.gradle` | 14 | 21.75 | 4.34 | [记录](archives/2026-09-10-docs-cleanup/a66126140e6ba9c638db.json) |
| `docs/verification/artifacts/2026-09-08/wallet-independent-activation/client/source/apps/mobile_flutter/build` | 6,629 | 1170.87 | 525.36 | [记录](archives/2026-09-10-docs-cleanup/7ddb869d169dfe5e1ae8.json) |
| `docs/verification/artifacts/2026-09-08/wallet-mfa-reauth/decoded` | 26,577 | 459.93 | 142.28 | [记录](archives/2026-09-10-docs-cleanup/a76ccf1e07b79e2c27c8.json) |
| `docs/verification/artifacts/2026-09-08/wallet-mfa-reauth/verified-decoded` | 26,007 | 426.58 | 127.47 | [记录](archives/2026-09-10-docs-cleanup/8f061d6ceb4d05ca03e4.json) |
| `docs/verification/artifacts/2026-09-09/mobile-parity/android-final-3239bee7/decoded` | 26,225 | 280.47 | 87.45 | [记录](archives/2026-09-10-docs-cleanup/5268883d34630e19c13b.json) |
| `docs/verification/artifacts/2026-09-09/mobile-parity/android-final-3239bee7/verified-decoded` | 25,675 | 252.35 | 74.93 | [记录](archives/2026-09-10-docs-cleanup/784cf186ffaefcb2fa0f.json) |
| `docs/verification/artifacts/2026-09-09/mobile-parity/android/decoded` | 26,225 | 280.46 | 87.45 | [记录](archives/2026-09-10-docs-cleanup/9ab26ad5ef266c175ee9.json) |
| `docs/verification/artifacts/2026-09-09/mobile-parity/android/verified-decoded` | 25,675 | 252.35 | 74.93 | [记录](archives/2026-09-10-docs-cleanup/bcaf7ed7fa5484c65e16.json) |
| `docs/verification/nomin36/src/apps/mobile_flutter/.dart_tool` | 34 | 83.30 | 29.06 | [记录](archives/2026-09-10-docs-cleanup/1f98b5ee65aa0fd77ed4.json) |
| `docs/verification/nomin36/src/apps/mobile_flutter/android/.gradle` | 14 | 21.03 | 3.94 | [记录](archives/2026-09-10-docs-cleanup/68fffed43f6079807df1.json) |
| `docs/verification/nomin36/src/apps/mobile_flutter/build` | 6,269 | 1048.00 | 470.93 | [记录](archives/2026-09-10-docs-cleanup/5b4d7356c7e8ce961aaf.json) |
| `docs/verification/plain36/src/apps/mobile_flutter/.dart_tool` | 34 | 83.48 | 29.16 | [记录](archives/2026-09-10-docs-cleanup/3ba78fba5ee7a81aeb84.json) |
| `docs/verification/plain36/src/apps/mobile_flutter/android/.gradle` | 14 | 21.06 | 3.93 | [记录](archives/2026-09-10-docs-cleanup/e9563cef37bb5ee1bc1e.json) |
| `docs/verification/plain36/src/apps/mobile_flutter/build` | 6,299 | 1058.31 | 479.18 | [记录](archives/2026-09-10-docs-cleanup/54af7e6c6e1e4e31578b.json) |
