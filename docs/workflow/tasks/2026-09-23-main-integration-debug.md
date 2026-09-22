# main 整合与 Mi6 Debug 交付

## 恢复入口
- 用户授权：合并本地分支到 main，整理 Git，安装新 Debug 到 Mi6，保留数据。
- 计划：docs/superpowers/plans/2026-09-23-main-integration-debug.md。
- 工作树：主目录；整合前 main=0125d50a；文件范围为分支差异、既有已完成回填、交付元数据。
- 当前状态：整合。已保存 inventory.json、main-working-before.patch、untracked-before.zip 到同日 main-integration-debug 工件目录。
- 下一步：提交现有完成修复，合并 phone-wallet-live-compat 与 Android040。

## 验收台账
| ID | 预期 | 状态 |
|---|---|---|
| GIT | 所有本地提交可从 main 到达，不丢脏树 | 处理中 |
| TEST | 最终整合源码测试通过 | 待验证 |
| APK | 固定签名完整重建与验包 | 待构建 |
| MI6 | 新 Debug 覆盖安装，数据保留 | 待安装 |

## 阶段计时
原始调查开始时间未完整记录，不估算精确耗时；后续阶段按工具日志记录。未发布生产，未推送 Git 远端。
