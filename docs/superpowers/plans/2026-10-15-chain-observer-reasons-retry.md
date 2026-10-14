# 链上观察原因传递与单调性重试

用户2026-10-15明确批准调查报告中的先原因传递、后保留单调性有界重试；此前服务器修改/部署授权继续有效。本有界计划不更改账本、钱包状态转移、最终性校验或通知分级/缓冲规则。

1. RED：已知头部倒退/冲突/总时限原因入runs并传至failed_conditions、事故及邮件；未知信息仍安全泛化。倒退后恢复、持续倒退、时间戳倒退、同高度冲突、截止预算、部分事件废弃和checkpoint不前进。
2. 原因仅白名单SOLID_HEAD_REGRESSED/SOLID_HEAD_CONFLICT/SCAN_DEADLINE；保持非TRANSIENT分类及P1，不对旧SNAPSHOT_FAILED历史数据猜测回填。
3. snapshot共享既有最多3次尝试和原90秒deadline，只有头部落后允许在预算足够时等待0.5秒完整重读；保持最高已见head；同高度冲突及高度/时间方向矛盾立即失败，禁止降低floor或复用部分数据。
4. 先独立领域/规格审查，再质量安全审查；跑相关API/worker/前端门禁及verify（当前.env缺失不导入生产秘密）。生产基线/hash/镜像重新采集，精确增量部署、保留回滚，不更新金融状态。

负责人root。文件：tron/reader.py、observer.py、funding_source.py、diagnostics.py；wallet/alert_context.py；worker/email_sender.py；必要的后台原因文字映射；相关测试、计划、任务与证据。复用im-reliability树(964fa788起)，保留main未提交文件。
