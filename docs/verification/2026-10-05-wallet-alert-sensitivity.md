# 钱包告警敏感度与邮件发布验收

用户批准“同意这套阈值和邮件方案”。2026-10-05 20:17 +08 完成生产验收。任务基线 4c8c16c7；所有源码增量位于独立 codex/wallet-alert-sensitivity 分支，保留主区其他变更。

A1–A3 已发布：监控不自动暂停；邮件描述实际问题和原因；确认的暂时故障连续 600 秒才通知，三次不同有效观察确认恢复。严重和未知原因即时告警。MANUAL_SOURCE_UNHEALTHY 保留 P1，既有精确预算超时保持 T2。没有变更账本、财务精度、暂停权限或资金证据期限。

## 验证

- 专项 red/green 覆盖 600 秒边界、重启、并发、恢复抖动、严重原因切换、时钟异常、诊断状态缺失、历史事件、上下文篡改、敏感字段拒绝与 SMTP 重放。
- 全量后端四分片：3918 通过、128 条件跳过；4 个旧契约测试失败，修正后相关 9 项通过，并由独立审查复测。最终钱包/邮件回归 1265 通过、31 跳过、1 既有 Starlette/httpx 弃用警告（189.41 秒）。不能将条件跳过称作 PostgreSQL 验收通过；最终镜像另外完成真实 PostgreSQL 恢复和并发验证。
- 门禁测试 34 通过；OpenAPI --check 通过。verify 仓库/部署/模板通过，render 缺本地 .env；ruff 未安装，完整 verify/lint 未通过。没有从生产取秘密来填本地环境。
- 最终候选 API/worker 经协议门禁通过；隔离恢复线上 PG 备份，0095 expand 成功，6 路并发失败只排一封告警，599/600 秒边界、三次不同观察、暂停控制保全通过。最终 worker 捕获完整中文邮件，重复事件只发送一次，未给真实邮箱发测试邮件。
- 兼容回退 API/worker 经同一协议门禁，schema95、新 cause_changed 事件消费、既有 SMTP 回执重放及暂停保全通过。回退保留扩展表，不执行 downgrade。
- 独立规格/领域审查后质量安全审查通过；最终测试更新、部署及回退脚本复审通过。proof 文件成功/角色/digest 校验已补充并只读复核通过。

## 生产身份与边界

API：sha256:58dca4884b89bc25839f9cfb652c67528f79473aca8ebcd79df2992f6509452f。

Worker：sha256:5a9cec63cc780e1e3cc769d3f249e120499bdfc5a37a99419302bd1c862bdbe1。

Watch 保留原镜像 sha256:961c3a0e1b9a32f40455ed1fe14cfa7e4a28ef9b6c2f139cb792108ca350b276，只切换已审查的源码挂载。schema：0095_wallet_source_alerts。24 个文件 SHA 与 manifest 相同，worker 核对实际 site-packages 导入路径。保留当次生产与仓库基线已有的观察历史/证据失效代码差异，没有夹带主区其他功能。

3 个服务健康、重启 0；环境键值、启动命令、挂载、资源及安全限制保全；所有其他基线容器 ID 不变。钱包 withdrawals_paused=false、pause_reason=null 保持。生产最新监控成功、last_error_code=null，新告警连续性状态无活动失败；切换后结构化 ERROR/CRITICAL 0。服务器与工作站经临时 jumper SOCKS 都得到 ready JSON 200，匿名管理员事故接口 401，TLS 校验保留。

最终镜像 probe 适配新通知去抖接口，仍保留原 9 个 API 和 8 个 worker 检查及严格门禁；新增真实 SQLite 600 秒/三轮恢复/管理员暂停保全断言。全局 probe 更新前 hash 校验且服务器备份，guard 本身未修改。

发布目录 /opt/starchat/releases/wallet-alerts-20261005；敏感 Compose、完整 inspect 与 PG dump 仅留服务器 private 0700/文件0600。隔离恢复容器/卷/网络与自己的 SOCKS 已清理。

## 证据索引

[生产](artifacts/2026-10-05/wallet-alerts/production-proof.json)、[运维与鉴权](artifacts/2026-10-05/wallet-alerts/operational-proof.json)、[最终文件清单](artifacts/2026-10-05/wallet-alerts/overlay-manifest.json)、[候选协议](artifacts/2026-10-05/wallet-alerts/protocol-proof.json)、[回退协议](artifacts/2026-10-05/wallet-alerts/rollback-protocol-proof.json)、[PG/API](artifacts/2026-10-05/wallet-alerts/api-domain-proof.json)、[PG/邮件预览](artifacts/2026-10-05/wallet-alerts/worker-domain-proof.json)、[回退消费](artifacts/2026-10-05/wallet-alerts/rollback-domain-proof.json)、[最终回归](artifacts/2026-10-05/wallet-alerts/final-wallet-regression.log)、[verify 限制](artifacts/2026-10-05/wallet-alerts/verify.log)。

原事件 ec3d15d3-ca19-47f8-b7ae-fc61d7635066 的证据支持采样不稳定和对账未确认，不能证明网络根因；历史已投递事件没有重写或重发。详见[任务调查](../workflow/tasks/2026-10-05-wallet-alert-sensitivity.md)。
