# 全局搜索与验证码跟进

## 恢复入口

- 用户2026-10-05要求S1全局搜索跳目标气泡、O1手机OTP15分钟、L1查短信阻塞、U1未同意协议toast、C1双渠道60秒离页冷却保留。
- 计划：[本轮计划](../../superpowers/plans/2026-10-05-global-search-otp.md)。源基线e3f10d6f；隔离worktree C:/Users/Administrator/.codex/worktrees/search-camera-history-20261003/StarChat；branch codex/global-search-otp-20261005。模拟器上轮实际2201；新候选尚未核号/构建。
- root文档/ADR/版本构建/只读生产；global_search_anchor_2202仅search模块及新测试；otp_client_cooldown仅auth模块及新测试。初始调查，不允许同文件/Flutter并发。
- 2026-10-05T03:50:39.6455167+08:00已读现行工作流/spec/ADR。代码证据：手机本地OTP300秒，阿里默认5min/校验上限10min；不同证明期限不可批量替换。手机登录controller冷却随页面销毁，其他Timer按tick而非deadline。
- 下一步：分别页面RED及短信期限ADR/domain review，生产聚合调查。不复用2201测试作为新变更通过证据。

## 验收台账

| ID | 预期 | 当前证据 | 状态 |
| --- | --- | --- | --- |
| S1 | 全局关键词命中定位正确事件/来源气泡及上下文 | route/source调查 | 未修复 |
| O1 | 所有手机OTP本地/供应商一致15分钟，安全规则保持 | phone.py300/config5min且max10 | 未修复/未部署 |
| L1 | 明确短信请求/投递/锁是否阻塞 | API/worker当前healthy；未分析日志 | 调查 |
| U1 | 无协议勾选toast且无请求 | auth actor调查 | 未修复 |
| C1 | 手机/邮件退出重进冷却继续 | 页面/controller Timer生命周期导致丢失 | 未修复 |

## 阶段与边界

生产只读观察03:53前后：business-api image2fd052541347、worker3efd5924f343健康；隔离recovery worker显示unhealthy需另行判断，不能冒称生产短信worker阻塞。无发送/账号修改/秘密读取或生产写入。整库verify环境仍需本轮预检。上轮1372无关WIP保全快照可作为本轮起点再次核对。

2026-10-05T03:55:15+08 L1只读聚合：48h API222514/gateway154101/worker6020日志行未命中列举SMS错误码；不代表未记录的运营商延迟不存在。OTP路由202/200可见，email-rebind429一例符合限流；PG当前无Lock waiters/阻塞PID，identity.email6事件全PUBLISHED/max2.548745s，identity.password_phone无48h事件，OTP无待发送活跃挑战。API及worker实际供应商配置5min；真实挑战期限300秒。没有日志request_time指标，不能推断API完整延迟分位数。原始日志只在远端RAM，落地仅计数/状态/期限。

03:56运行来源：API2fd052541347…/opt/business-api/app，worker3efd5924f343…site-packages/app；config/phone内容两角色不同，禁止全repo覆盖运行worker。短信期限rootdomain设计接受，邮箱注册10min/其他EMAIL5min及非OTP证明保持；候选必须应用实际base最小变换、保留所有非短信差异。SDD新serveragent因threadlimit无法创建，复用已完成prepare_recovery_deployment新边界，不重新执行旧任务。
