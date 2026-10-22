# 链上观察P1事故只读排查

用户授权检查服务器频繁报错。root领取本调查文档与artifacts/2026-10-15/chain-observer-alert，不修改产品或资金状态。2026-10-15 06:02–06:04+08采集生产watch/业务数据库/实际源代码。事件与run100510对齐：SOLID_HEAD_REGRESSED被降为SNAPSHOT_FAILED→SOURCE_RUN_ERROR，未命中600秒通知缓冲；05:37:53条件已清除，OPEN未人工结案。近24h 2/2612运行失败、近7d 3封SMTP告警；发送尝试1。本次调查完成，修复方案及完整证据见[报告](../../verification/2026-10-15-chain-observer-alert.md)。下一步为原因枚举贯通及严格保护边界下的有界完整快照重试设计/评审/回归；没有部署、钱包写入或后台任务遗留。
