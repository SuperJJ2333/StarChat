# 钱包交接 CI 证据文件权限测试修复

用户要求核查31个HANDOVER_DEPLOYMENT_EVIDENCE_UNAVAILABLE失败并修复。范围仅测试fixture与测试证据，不修改生产钱包、权限或部署校验。

原因调查：handover fixture已经创建完整JSON并chmod0600；load_deployment在非Windows额外要求st_uid==0，普通Linux CI用户创建的文件不满足。不能添加简化ready文件，也不能取消root归属校验或将整套CI提权。

执行：先复现非root POSIX读取导致503；对指定fixture文件仅模拟root归属，保留真实读取、JSON、权限、哈希、来源及时间校验；加入非root/宽权限/无文件/坏内容拒绝与fixture隔离测试；执行原失败测试组、完整verify及Linux CI。验证规格后独立质量安全审查，提交main。生产与移动安装包不变。

root拥有tests/business_api/wallet/test_legacy_handover.py、新增测试helper/部署证据边界测试、本计划及验证报告。当前根目录有其他任务文档清理，使用.worktrees/handover-ci-ownership隔离，不覆盖其文件。
