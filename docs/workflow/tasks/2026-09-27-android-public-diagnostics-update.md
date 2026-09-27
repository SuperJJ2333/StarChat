# Android 正式诊断增量及更新弹窗

## 恢复入口

- 用户授权：本轮明确“请你推送Android版本的更新弹窗，部署新版本更新”，授权正式Android工件、ARM64下载别名及平台更新设置/审计。沿用已有修复及诊断方案，无新服务部署授权要求。
- [计划](../../superpowers/plans/2026-09-27-android-public-diagnostics-update.md)。复用干净worktree C:/Users/Administrator/.codex/worktrees/network-failure-diagnostics/StarChat，起始7171df8a。root拥有版本/工件/发布/文档，agent只读review。
- 当前：准备；拟0.4.19/2188，待读取生产占用。旧Debug2187移动1779项与1939c62b冻结manifest一致，锁314504b9…76bf3，已有API e304生产接收端；历史错误原因未确定。
- 下一步：fresh生产baseline与版本确认，版本专项、正式ARM64构建与固定签名、部署更新弹窗。

## 验收台账

| ID | 预期 | 当前证据 | 发布/缺口 |
| --- | --- | --- | --- |
| D01 | 包含验证码拒绝释放、锁屏门槛、消息性能/历史索引和请求失败诊断 | 2187已验证输入逐项一致；仅新版本差异计划 | 正式工件待构建，K80/iOS真机不能由模拟器替代 |
| D02 | ARM64 release、固定签名、版本递增与重建门禁 | 工具及固定身份存在，无秘密输出 | 待正式构建 |
| D03 | 不可变APK/ARM64别名/更新弹窗三键审计 | 已授权，已有无重定向publisher流程 | 待fresh baseline及发布 |
| D04 | iOS/notes/minimum/其他ABI/静态/容器保持，双侧TLS | 读取并留本次证据 | 未伪造生产登录，设备弹窗反馈另列 |

## 证据和时间

新证据：docs/verification/artifacts/2026-09-27/android-public-diagnostics-update；大工件E:/StarChatVerification/docs/verification/artifacts/2026-09-27/android-public-diagnostics-update。旧全量及影响闭环按mobile-delivery-workflow复用，命令/退出和SHA见network-failure-diagnostics任务。不称原全量exit0。阶段起止按真实工具时间，初始用户消息准确时刻未知。

## 回退与交接

新stage与0700持久备份独立；回退先核对本次revision仍当前，仅旧三键通过SettingService审计恢复，ARM64别名CAS恢复。保留不可变包与审计，不盲目重放不确定提交。主目录其他任务修改保持，不进行Git远端推送。
