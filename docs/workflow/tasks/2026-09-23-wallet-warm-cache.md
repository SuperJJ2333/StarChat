# 钱包缓存、冷启动与记录页

- 授权：用户2026-09-23钱包/充值/提现缓存及钱包记录参照全部账单要求；执行[批准计划](../../superpowers/plans/2026-09-23-debug-feedback.md)。
- 工作树：`.worktrees/debug-feedback-2164`，基线 `e8bf1440`，wallet_warm_cache拥有wallet页/读缓存、finance进入store、ledger共享行抽取、对应测试及HTML finance/wallet-binding/components样式增量。
- 状态：源码与定向验证完成，独立审查通过。最后更新2026-09-23 20:33 +08:00。未单独构建、安装或发布；集成由root执行。
- 下一步：root汇总UI registry/契约与全量门禁、Debug2164构建安装证据；真机验证钱包进入、冷启动断网、恢复网络及账号切换。

| ID | 验收 | 实现/证据 | 真机 |
| --- | --- | --- | --- |
| W1 | 冷启动保留钱包/充值/提现/汇率/记录内容 | 既有WalletEntryStore和快照存储复用；充值/汇率/记录独立资源作用域；提现本地读取移到联网前 | 待用户 |
| W2 | 失败保留旧值，写前仍核验 | 旧充值二维码不开放；过期FX标记stale；fresh余额获取失败阻止依赖操作；手动重试可更新 | 待用户 |
| W3 | 账号隔离 | origin+subject作用域、session epoch、gateway固定scope；同页面换client/scope/epoch重绑；晚到请求不落盘 | widget/unit通过 |
| W4 | 少重复请求 | 30秒成功内存快照进入窗口；冷盘快照始终刷新；显式刷新不受窗口限制；inflight合并 | unit通过 |
| W5 | 记录页参照全部账单 | LedgerRecordRow与formatLedgerShortTime共用；类型筛选、中文状态、缓存失败重试；明确最近50条 | 待用户 |

## 阶段与证据

开始精确时间未知，不能按文件时间推算。20:23 +08专项165通过；20:29最终账号保护补丁；20:32:21仅花括号lint调整；主动工时与历史工具总耗时未精确记录。

红证据：①旧账号inflight请求结束后缓存hasData实际true，预期false；②完全离线提现冷启动找不到本地申请卡；③钱包HTML记录没有账单行；④同State无Key换账号仍残留LedgerRecordRow。四项均先观测失败后转绿。详见[验证](../../verification/2026-09-23-wallet-warm-cache.md)。

无金融服务端、账本公式、幂等协议、支付密码、钱包状态转换变更。保留既有ManualOperationStore幂等恢复。可回退本任务文件增量；缓存新资源只读，无迁移。
