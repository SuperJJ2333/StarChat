# Flutter 手机契约复审任务

- 授权：承接用户连续代码复审/纠错，检查最新 Flutter API 契约交付。用户短信验证已完成，不重发；本轮无 UI 扩展、生产或真实资金操作。
- 批准计划：2026-09-21-pricing-auth-redpacket-group-program；ADR-0075。
- 所有权：根任务独占 business_api_client.dart 手机段、business_phone_contracts.dart 注释、原客户端测试和新增 review 测试、本轮文档；phone_contract_quality 仅只读独立规格及安全复核。
- 基线：worktree phone-client-audit，153 相关输入快照；没有复制真实 .env。
- 状态：冷却和超时缺陷已复现修正；17 专项、3702 Flutter 全量、analyze、228 边界及影响门禁通过。同输入后端门禁复用，上轮 58 skips 未验证。
- 时间：快照时间见 input-snapshot.json；16:38 前完成有效红绿复现；Flutter 全量约 3 分钟，16:43 已核对；16:46 影响门禁完成。前期锁文件/脚本修正如实见报告。
- 交付：按源文件哈希差量回填，具体时间/文件/回退副本见 applied-changes.json；不覆盖其他任务。
- 下一条操作：按更新 prompt 推进 Flutter UI/状态恢复及真机，不重复已验服务端与供应商 SMS。
- 详情：[复审报告](../../verification/2026-09-22-phone-client-code-review.md)。
