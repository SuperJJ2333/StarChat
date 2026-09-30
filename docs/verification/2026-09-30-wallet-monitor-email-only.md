# 钱包监控仅邮件告警：实现与生产证据

日期：2026-09-30。生产发布：14:00 前完成，精确切换完成 13:59:33 +08。授权：用户批准 ADR 与两份计划。隔离分支 `codex/wallet-alert-only-payout-void`，基线 `971fb50d`；当前逐文件 SHA 见 `artifacts/2026-09-30/source-identity.json`，最终部署身份见 `deployment-proof.json`。

## 验收

| ID | 结果 |
| --- | --- |
| M1 所有监控事故不自动暂停 | 人工储备、旧监控、定时对账及孤儿扫描已删除自动控制写入。生产 worker 的实际 site-packages 路径同步更新。 |
| M2 邮件、事故与审计保留 | maintenance 将返回信号送入事故/Outbox；去重、重试和 T2 保留。目标事故原有 8 个告警事件均有 SMTP 接受回执；接手后无新升级邮件符合现有去重规则。未额外发送测试邮件。 |
| M3 旧暂停不自动解除 | 14:03、14:04 两次读回三项限制均 true，控制 epoch 均 2774；期间监控继续发现 MANUAL_PAYOUT_UNCERTAIN，没有新增暂停审计。 |
| M4 发布与鉴权 | API/worker healthy、restart=0，其他 28 容器不变；未授权撤销 POST 返回 401；六个公开静态文件 SHA 与部署清单一致。 |

## 验证与复用

- 测试先红后绿：监控原自动暂停断言和 maintenance 缺失事故发布由实现者验证失败后修正。整合后 monitor/maintenance 定向 86 passed（8.26 秒，exit 0）；此前 monitor 范围 144 passed/1 skipped、maintenance 38 passed。
- `python -m pytest tests/business_api tests/business_worker -q --disable-warnings`：2961 passed、77 skipped、2 failed、1 warning，30m04.13s，exit 1。两项失败仅为旧 head=0088 的硬编码断言；修正后 migration/release-baseline/void-migration 18 passed、1 skipped，17.64 秒，exit 0。后续授权及兼容代码变更按影响范围追加定向测试，未重复整段 30 分钟回归。
- 最后前端全量 `node --test frontend/tests/*.test.mjs`：318 passed，exit 0，1.63 秒；日志 `artifacts/2026-09-30/frontend-final.log`。OpenAPI `scripts/export_openapi.py --check` exit 0。
- `pwsh -NoProfile -File scripts/verify.ps1`：仓库策略、部署策略、模板工具 PASS，RenderOnly 因隔离工作树缺 `.env` 退出 1。没有导入生产秘密以补此门禁；不宣称完整 verify 全绿。金融候选独立完成 PostgreSQL、最终镜像与生产发布门禁。
- 窄 lint F401/F841 通过，diff check 通过。全量 ruff 中旧 E701/E702 历史风格未在本任务批量格式化，不宣称全仓 lint 全绿。

## 发布身份与回退

- API：`sha256:902eaefcb237924caf9b60145f728f9e2b4ec67fc2b659bd98ad7ea82edd101f`。
- worker：`sha256:90d7fb7472c82b78b9a9a56ef114620dd0aa0bd4a989e3011e3aa4ed24537282`。
- 实际 Compose：`/opt/starchat/releases/guarded-to8ny40i/compose.json`，通过服务器现行 role-aware `business_release_guard.py deploy` 切换。现行参数为 `--api-image`、`--worker-image`，旧文档中的 `--image` 未执行切换且被拒绝。
- 精确覆盖当前生产镜像，保留用户目录、钱包只读授权、后台 capabilities/search 等并行功能。worker 原实际导入 site-packages，不能仅覆盖 `/opt/business-api`；已核对实际源路径。旧 gate 要求导出 `apply_manual_pause` 供探针替换，因此保留无调用的模块导出；所有监控调用删除。
- 兼容回退：`/opt/starchat/releases/wallet-alert-only-20260930/private/compatible-rollback.json`；API `78ced987…63676`、worker `bb7bd0eb…57422`，两角色协议门禁通过，保留邮件政策和 VOIDED 读取，关闭新撤销端点。切换回退仍必须走同一 guard，不降数据库。
- 私有数据库备份、配置、日志留服务器 0700 发布目录；数据库备份未回传工作站。公网正确健康路径 `/api/v1/health/ready` 两端返回 ready JSON；首次误用 `/health/ready` 得 404，已纠正。API 无 ERROR/Traceback；worker 的 ERROR 原因仅为仍待处置的 MANUAL_PAYOUT_UNCERTAIN，无 Traceback。

## 审查与未完成项

规格审查之后完成领域审查，再完成质量/安全审查；最后 scoped PASS。现有生产订单撤销、事故结案、独立恢复尚待真实官方管理员操作验证，不能把部署视为资金恢复。
