# 新加坡根分区/XFS在线扩容

授权依据：用户交接指定40GiB卷后，按具体步骤将StarChatSgMaintenanceRole绑定EC2，并回复“已绑定”。此前告知的执行顺序为核验权限→创建目标卷快照→等待completed→分区/XFS在线扩容→读回容量；本计划只执行该顺序。

1. 严格SSH/jumper、IMDSv2确认实例i-035b46916e4cf43eb，AWS查询确认vol-019dd3dc00b9a08bd/gp3/40GiB/ap-southeast-1a仅挂载该实例。根挂载须为/dev/nvme0n1p1/XFS，NVMe serial对应该卷；重新读完整GPT结构、boot_id、系统磁盘错误与SSH状态。
2. 远端0700维护目录保存分区布局与身份。不获取/导出IAM凭证；sync后创建仅目标卷的本次快照，固定标签StarChatPurpose=sg-root-expansion与StarChatInstance=i-035b46916e4cf43eb。创建前检查本次状态/标签，避免成功但响应丢失导致重复创建；未知创建状态先查快照再继续。
3. 分次查询已记录快照的State/VolumeId/StartTime，源卷/区域/任务标签匹配且completed后才能扩大分区。不得拿旧AMI或旧卷快照代替。
4. 写入前重读实例、卷、挂载及所有分区布局，与本次基线一致；仅growpart /dev/nvme0n1 1。扩大后核对p1 start、UUID/类型与EFI/BIOS分区不变，内核p1容量接近40GiB；再xfs_growfs /，不进行格式化、重启、缩容或改boot分区。
5. 读回lsblk/sfdisk/xfs_info/statvfs，确认FS接近40GiB、实际可用空间、boot_id未变、SSH可重连、无新XFS/NVMe/I/O错误。本轮不会验证从快照恢复启动；XFS不可原地缩回，回退依赖保留快照新建卷恢复。
6. 公共身份/结果/计时放docs/verification/artifacts/2026-09-27/singapore-node-readiness，私有维护目录不含业务或秘密。更新任务、报告及索引，区分扩容完成与边缘服务/主区升级未执行。

无需重新授权已批准的快照与在线扩容。未授权创建实例、改安全组、DNS/香港/TURN或主区数据迁移。
