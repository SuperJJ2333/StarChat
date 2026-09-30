# Outbox 消费契约与网关模板同步 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 补上真实、幂等的内部事件接收端，停止当前契约缺口持续产生死信，并恢复配置模板与现网语义/渲染一致。

**Architecture:** Worker调用公共AuditWriter追加确定性内部接收回执，成功后按原有租约确认；不执行金融命令或通知。模板同步现网已批准安全规则，私有候选须保持完整配置语义，漂移守卫继续严格。

**Tech Stack:** Python3.12、SQLAlchemy、PostgreSQL16、pytest、nginx、Synapse、PowerShell7、严格SSH。

授权：用户本轮明确要求解决两项问题，按[规格](../specs/2026-09-27-outbox-gateway-reconciliation-design.md)连续执行。独立worktree为 `C:/Users/Administrator/.codex/worktrees/outbox-gateway-reconciliation/StarChat`，当前MAIN的972项非秘密源码输入及SHA见任务证据 `worktree-source-baseline.json`；不得拿HEAD覆盖dirty MAIN或并行生产API。

### Task 1：内部发布契约

Files：Modify `services/business-api/app/modules/audit/writer.py`、`services/business-worker/app/main.py`；Create `services/business-worker/app/tasks/internal_publication.py`、`tests/business_worker/test_internal_publication.py`、`tests/business_api/audit/test_outbox_publication_receipts.py`。实现者先冻结精确公开生产者契约；不得修改ledger/wallet服务。

- [x] RED：真实Outbox产生两个当前活跃事件，装配Worker后应拥有耐久AuditWriter回执且PUBLISHED；当前缺consumer导致测试失败。增加重复/失ACK、冲突、非法信封、不支持通知/未知topic、数据库异常测试，逐项记录真实缺失行为。
- [x] GREEN：固定11内部topic及公开事件契约，完整稳定信封canonical JSON SHA256，排除attempt_count等租约可变字段；确定性UUID5回执经公共AuditWriter保存并严格等价校验。只记录版本/topic/type/digest；数据库失败传递给原Worker重试。
- [x] 验证：`$env:PYTHONPATH='services/business-api;services/business-worker/app;.'; py -3.12 -m pytest tests/business_api/audit tests/business_api/test_outbox.py tests/business_api/test_outbox_handover.py tests/business_worker -q` 应全部通过；Ruff仅检查归属变更；独立PG实例验证唯一主键并发、ACK丢失、原业务/原审计未改。

### Task 2：模板同步及发布守卫

Files：Modify `infra/nginx/nginx.conf.template`（仅若必要的位置对齐）、`infra/synapse/homeserver.yaml.template`（当前契约保留）、`tests/infra/test_render_config.py`；Create 本任务证据目录内公开发布/验证工具及tests。不修改SG、业务API或鉴权模块代码。

- [x] RED：用脱敏最小fixture复现服务器模板漏安全块/模块；回归断言拒绝缺块候选，并保留完整broker/拒绝/隐藏规则、5TURN、S3同步读写配置和Module声明。
- [x] GREEN：同步正确模板；候选必须从当前运行配置私有备份派生验证，未解析token、语义差异、身份变化、权限/挂载变化均停止写入。不要让check忽略真正漂移。
- [x] 验证：`py -3.12 -m pytest tests/infra -q`；实际相关路由文件为 `test_push_gateway_routing.py` 与 `test_synapse_mobile_login.py`，新增发布工具测试另跑任务证据目录的固定文件。候选nginx原镜像 `nginx -t` 通过，完整Synapse模块/provider/TURN/其它字段相等，所有公开鉴权HTTP检查通过。

### Task 3：审查、门禁及分批发布

- [x] 先进行独立规格/领域审查，再进行质量/安全审查；修复全部阻断，记录工具/源码/输入SHA和退出码。
- [x] `pwsh -NoProfile -File scripts/verify.ps1` 环境预检后执行一次；证据复用仅限输入及阶段等价，原失败不得抹掉。缺少当前移动输入时先冻结其实际来源再执行相关门禁，不覆盖他人文件。实际原exit1保留，补齐当前packages/frontend后按mandatory-verification-impact-closure.json闭合。
- [x] 从当次实际worker镜像叠加归属源码（实际site-packages路径一并核验），独立Linux/PG演练、配置挂载与PHONE/S3保留检查。切换只限worker；API或其它容器漂移时重新取基线，不覆盖新发布。
- [x] 模板先上传公开输入，私有候选比较后原地写入保持inode/权限，必要时只reload nginx；Synapse语义不变无需restart。失败按本批私有备份恢复并重新验证。
- [x] 严格 `render_config --check --require-production` exit0，公开TLS ready/login鉴权/register403/admin404保持；实际新事件的内部回执/成功状态、未知事件及历史DEAD保留验证。跨过reaper宽限窗口后再作生产结果结论。
- [x] Root按SHAbaseline CAS回填MAIN归属文件，更新任务/验证/runbook/current-state，链接与证据输入一致性检查。
