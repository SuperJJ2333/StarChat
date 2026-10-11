# R7a 独立复审

审查对象75d2c969 + 1284772e，root非作者。先规格/领域，后质量安全。

规格：PASS（源码候选）。固定head/read-boundary ID快照；每页最多256正文，旧页释放后下一页；interactive维护预算；checkpoint仅在完整区间且持久化成功后提交；维持v2顺序与账号/历史generation。首次发现prefs.setString=false与网络期间独占维护lease两项缺口均已由作者修复，并再次读取源码及新增用例核对。

质量安全：PASS。关闭/账号切换/历史generation改变取消正文读取，不让迟到future保留全量body；SDK公开requestHistory只在固定tail后扩展，跨网络释放重型lease，回来重新获取；失败checkpoint回滚且SharedPreferences缓存reload。未写跨模块表或更改E2EE。

独立运行四测试文件：mention_history_scan、mention_scan_cancellation、mention_timeline_order、unread_mention_tracker，32PASS，日志r7a-independent.txt。作者55PASS仅作相邻补充，不冒充独立计数。源码检查和测试在本轮完成；精确审查起止未完整计时。

限制：快照ID列表、seen与v2提及元数据仍O(N)；首轮发现ID的总耗时、iOS/Android帧与大群真机尚未验收。这份通过不代表R7所有性能目标达成。
