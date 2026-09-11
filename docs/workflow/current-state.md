# 移动交付恢复索引

更新日期：2026-09-10（Asia/Hong_Kong）。这里只是最近证据索引；部署前必须重新读取生产，不能把此文件当实时状态。每个任务拥有独立记录，新增任务不要覆盖其他任务条目。

| 事项 | 最近已确认状态 | 证据/下一步 |
| --- | --- | --- |
| iOS企业版 | 0.3.81/2085已发布，包SHA762fb649…37d37f2 | [发布记录](../verification/2026-09-10-ios-0381-enterprise-publication.md)；等待iPhone覆盖安装、语音、保存记录后重登反馈 |
| Android正式版 | 发布观察值0.3.80/2084；0.3.81/2085仅候选 | [2085候选](../verification/2026-09-10-platform-release-2085.md)；未获新的发布任务时不把候选自行上线；发布前核对当前API的Android platform标记兼容性 |
| 旧iOS2073更新 | 共享投影标题仍可能显示0.3.80，设备页桥接安装iOS2085 | [过渡限制](../verification/2026-09-10-ios-0381-enterprise-publication.md)；不能声称旧二进制已具有平台隔离元数据 |
| L04后续服务端修复 | 另一任务提交0b1a07c5、记录910f653e：SDK登录类型前置检查导致失败，服务端兼容公告已部署；POST仍拒绝密码型登录 | [L04追加记录](../verification/2026-09-10-mobile-0380-2084-release.md)；下一客户端版本的token-only预检查修复仍待实现，不将此待办算入既有2085包 |
| 钱包CI31失败 | fixture POSIX归属修复；Ubuntu1815通过/49跳过 | [CI证据](../verification/2026-09-10-handover-ci-ownership.md)；不需要因此重新生成既有移动包 |
| 跨会话工作流 | 根AGENTS已挂接操作手册与此索引 | [工作流](../runbooks/mobile-delivery-workflow.md)、[任务模板](task-template.md)、[本次工作流任务](tasks/2026-09-10-delivery-workflow.md) |

无新增版本/提交声称：本次工作流配置不发布APK、IPA或业务服务，不改变现有更新设置。

## Mi 6 朋友圈与聊天Debug（2026-09-11）

本任务独立分支已交付0.3.82-debug/2086到Mi 6，未生产发布。功能测试按用户要求未执行，待用户验收。[任务记录](tasks/2026-09-10-moments-im-mi6.md) · [根因与安装证据](../verification/2026-09-10-moments-im-mi6.md)。

## Mi 6 钱包重构（2026-09-11）

钱包标题保持“钱包”，TRON绑定门槛、点钻1:1零费最低10USDT提现及支付密码已实现；debug 0.3.83/2087已安装Mi 6，配套API已部署，真机交互待用户验收。[任务记录](tasks/2026-09-11-wallet-binding-payment.md) · [验证与实际镜像](../verification/2026-09-11-wallet-binding-payment.md)。此条仅代表本任务观察，不覆盖其他任务发布条目。

## 2026-09-11 性能专项

| 事项 | 状态 | 证据 |
| --- | --- | --- |
| 性能专项 Android/iOS | Astra 实际差异审查、显式 Terra 执行已完成本地性能批次；Flutter 2199通过/29钱包用例失败，全量分析及Android arm64源码编译通过；全量验收仍未通过，iOS原生与真机待验收；未push/部署/生产操作 | [任务记录](tasks/2026-09-11-performance.md) · [本地验收记录](../verification/2026-09-11-performance-local-acceptance.md)；无新版本安装或发布 |

## 2026-09-11 红包、转账与点钻账单（本地实现与审查完成，真机待验收）

当前performance工作树中的红包/转账/点钻账单实现与本地审查完成，Astra主审、显式gpt-5.6-terra实施。真实入口/详情/账单/群人数定向验证通过；全Flutter2310通过/29基线失败，analyze和ARM64源码编译通过。全仓其他既有失败与未验证真机/多端见报告；未发布或安装新版本。[任务记录](tasks/2026-09-11-finance-chat.md) · [计划与验收用例](../superpowers/plans/2026-09-11-finance-chat.md) · [审查记录](../verification/2026-09-11-finance-chat-review.md)。


## 2026-09-11 main合并、跳板部署与Mi 6 Debug2088

全部本地分支已合并到main并推送，源代码候选6be55572；生产API候选a397ecd9已通过跳板部署，8API/13静态文件、健康/鉴权/哈希/隔离恢复通过，未迁移DB。Mi 6实际覆盖安装0.3.84-debug/2088，固定签名与已安装原包一致，实际APK哈希bd7c1e97…de0aebb，原数据未清除。Flutter2344通过/29既有钱包失败、analyze通过，用户真机测试待验收。此次记录更新之前的未发布状态，仅覆盖本次明确范围，Android/iOS正式更新设置未修改。[任务](tasks/2026-09-11-integrate-deploy-mi6.md) · [交付报告](../verification/2026-09-11-integrate-deploy-mi6.md)。
