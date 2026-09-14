# 人工补录生产发布计划

用户已授权发布；沿用ADR0069与已验收M1–M4，不改金融逻辑。

- [x] P1 Astra核对现网源码/镜像/配置，Terra整理有限overlay清单及输入hash。仅本次已验收代码与必要依赖；保留现网账本功能。验收：逐文件diff与manifest闭合。
- [x] P2 Terra编写发布工具及针对性门禁测试，Astra审查执行。持久备份、真实隔离恢复、候选迁移到0066、PG约束/并发测试；旧应用兼容扩展schema，候选配置仅image及已授权人工修复flag变化，回退恢复原flag。验收：候选digest+dump绑定证据。
- [x] P3 Astra执行批准清单：0065/0066扩展迁移，重建business-api，原子替换清单静态文件；不动其他服务、不实际补款。验收：hash/schema/健康与未知漂移拒绝。
- [x] P4 Astra验证公网TLS/资源、API健康JSON、未授权拒绝、日志和其他服务不变，更新任务与报告。无管理员凭据时如实记录不能生产写入验收。回退保留schema与审计，不破坏性downgrade。

生产119e6971、schema0066、双侧HTTPS验收完成，证据见[发布报告](../../verification/2026-09-13-manual-deposit-production.md)。
