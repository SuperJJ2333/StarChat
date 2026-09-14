# 人工补录生产发布

授权：用户2026-09-13明确要求部署生产。包含已验收人工补录及后台客服依赖；不执行实际充值，不发布移动客户端。当前工作区不clone/pull/reset，精确overlay基于现网镜像。
主审：Astra；显式gpt-5.6-terra执行release_manifest及release_tooling，最多两人，独立文件。
开始：2026-09-13 12:32+08（精确工具起点未记录）；状态：生产发布及验收完成。
计划：[发布计划](../../superpowers/plans/2026-09-13-manual-deposit-production.md)。
生产基线：API sha256:eb14b5969f5a6953c17ef0186c99e195fbec606241172bc4c370edaa15137038，compose /opt/starchat/releases/ledger-counterparty-20260913/business-api-release.json，schema0064_admin_deposit_repairs。当前观察，不复用历史镜像。

| ID | 内容 | 状态 |
| --- | --- | --- |
| P1 | 冻结manifest、diff、输入证据与现网漂移 | 完成 |
| P2 | 备份、隔离恢复、0065/0066迁移、候选兼容及回退演练 | 完成 |
| P3 | 迁移并仅切换API与清单静态资源 | 完成 |
| P4 | 生产健康、鉴权、hash、其他服务与公网检查 | 完成 |

证据：docs/verification/artifacts/2026-09-13/manual-deposit-production/。敏感compose及数据库备份只留服务器0700发布目录。
下一步：用户刷新后台，按操作手册执行需要的业务核对与审批。未进行实际补款。

12:49+08生产切换完成：API119e69710767…、schema0066、14镜像覆盖/6后台JS，人工修复开关由默认false显式启用，owner/grant不变；其他容器不变。候选Linux80项、发布脚本15项通过。12:50工作站HTTPS及隧道关闭完成。[实际发布/备份/回退/限制](../../verification/2026-09-13-manual-deposit-production.md)。
