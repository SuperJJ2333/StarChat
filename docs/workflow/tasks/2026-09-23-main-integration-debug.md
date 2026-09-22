# main 整合与 Mi6 Debug 交付

## 恢复入口
- 用户授权：合并本地分支到 main，整理 Git，安装新 Debug 到 Mi6，保留数据。
- 计划：docs/superpowers/plans/2026-09-23-main-integration-debug.md。
- 工作树：主目录；整合前 main=0125d50a；文件范围为分支差异、既有已完成回填、交付元数据。
- 当前状态：整合、验证和2159 Debug真机安装完成，待用户业务反馈。已保存 inventory.json、main-working-before.patch、untracked-before.zip 到同日 main-integration-debug 工件目录。
- 下一步：用户Mi6复验会话切换、手机换绑、充值/提现汇率和取消充值；有反馈时以本次2159来源为基线。

## 验收台账
| ID | 预期 | 状态 |
|---|---|---|
| GIT | 所有本地提交可从 main 到达，不丢脏树 | 已完成；保留脏树与本地配置 |
| TEST | 最终整合源码测试通过 | Flutter3870、frontend245、手机10、mobile108/1，契约/迁移/Compose通过；后端2544/59等输入证据复用 |
| APK | 固定签名完整重建与验包 | 0.4.1+2159通过，来源c7cff671 |
| MI6 | 新 Debug 覆盖安装，数据保留 | 03:20:17+08:00安装并启动，待用户业务复验 |

## 阶段计时
原始调查开始时间未完整记录，不估算精确耗时；后续阶段按工具日志记录。未发布生产，未推送 Git 远端。

详见[本次验证报告](../../verification/2026-09-23-main-integration-debug.md)。

完成记录时间：2026-09-23T03:27+08:00。本次测试、构建、安装进程均已结束；无待运行后台验证任务。
