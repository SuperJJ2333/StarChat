# 新加坡实例交接与根盘扩容验证

用户交接实例`i-035b46916e4cf43eb`、公网`13.229.60.153`与`vol-019dd3dc00b9a08bd`，声明gp3/40GiB；访问使用本机已有密钥经jumper。先只读核验，随后用户明确`StarChatSgMaintenanceRole`已绑定，按告知的顺序创建快照并完成分区/XFS增长。不部署边缘服务/改DNS/迁主区，不取出私钥、TURN密钥或IAM凭证。[任务](../workflow/tasks/2026-09-27-singapore-node-readiness.md)

## 最终结果（2026-09-27 14:27 +08）

角色权限现场生效，AWS确认目标卷为gp3/40GiB/ap-southeast-1a、仅挂载所交接实例；原卷Encrypted=false，本次未改变该属性。扩容前快照`snap-0f0329f5092ee868b`于14:13:49创建，14:21:09查询已completed/100%，源卷、任务标签与时间均匹配。[快照身份](artifacts/2026-09-27/singapore-node-readiness/snapshot-created.json)、[完成状态](artifacts/2026-09-27/singapore-node-readiness/snapshot-status.json)。

14:23:40–14:23:44执行growpart及xfs_growfs，退出0；14:27:22–14:27:25重新SSH连接并完整复核，退出0：

- 根分区42937073152字节≈39.99GiB，根XFS42869960704字节≈39.93GiB，可用40876273664字节≈38.07GiB。
- p1起点、UUID、类型以及EFI/BIOS分区保持不变；GPT备用布局扩至40GiB边界。boot_id不变，未重启，sshd active，内核磁盘/XFS错误计数0。
- 在真实写入前运行10个布局保护测试，验证错误起点/UUID、启动分区变更、额外分区、GPT身份及容量越界均被拒绝；测试退出0。先规格核对，再质量/安全复核实际命令与身份；未把这些操作脚本测试称为应用功能的test-first证据。

[实际扩容](artifacts/2026-09-27/singapore-node-readiness/root-expanded.json)、[重新连接后的复核](artifacts/2026-09-27/singapore-node-readiness/root-verified.json)、[布局保护](artifacts/2026-09-27/singapore-node-readiness/expansion-guards.log)。远端0700维护目录`/opt/starchat/maintenance/sg-root-expansion-20260927`保存本次基线、分区表、快照ID与结果。快照创建前sync；这是运行根卷的恢复点，未另外启动恢复实例/验证快照启动，不宣称完成恢复演练。执行依据[用户授权扩容计划](../superpowers/plans/2026-09-27-sg-root-expansion.md)，使用[AWS官方Linux扩容流程](https://docs.aws.amazon.com/ebs/latest/userguide/recognize-expanded-volume-linux.html)。

## 交接时的现场结果（历史基线，2026-09-27 12:19 +08）

| 项 | 实测 |
| --- | --- |
| SSH/实例身份 | 严格主机校验、BatchMode经jumper成功；IMDSv2返回所交接instance-id及公网地址 |
| 类型/区域 | c5.xlarge，ap-southeast-1a，x86_64，4逻辑CPU |
| 系统/内存 | Amazon Linux2023.12，MemTotal8054640640字节≈7.50GiB，可用≈7.10GiB，无swap |
| 目标卷 | NVMe serial `vol019dd3dc00b9a08bd`，与交接ID匹配；裸盘42949672960字节=40GiB |
| 根分区/FS | `/dev/nvme0n1p1`为XFS；分区8577334784字节≈7.99GiB，FS8510222336字节≈7.93GiB，可用6757617664字节≈6.29GiB |
| 运行服务 | 未安装Docker，无业务/TURN/HTTP监听，TCP只有SSH22；不宣称AWS安全组是否已开放其它端口 |
| 系统参数 | 临时端口32768–60999与草案TURN relay段重叠；conntrack参数文件当前不存在，未加载/调参 |
| AWS查询 | AWS CLI存在，但DescribeVolumes/DescribeSnapshots均退出253、credentials_unavailable；gp3/加密/EIP/安全组由账号API尚未核实 |

**40GiB只到了块设备，分区和文件系统尚未扩容。** `growpart -N /dev/nvme0n1 1`退出0，显示p1 start保持24576、size拟从16752607增长到83861471扇区；`xfs_growfs -n /`退出0。这两个都是不修改检查，不能写成扩容成功。[现场库存](artifacts/2026-09-27/singapore-node-readiness/live-inventory.json)、[模拟检查](artifacts/2026-09-27/singapore-node-readiness/expansion-preflight.json)。

新加坡主机向现有香港公开API做5次有界HTTPS健康检查，全部200、ok=true/database=ready，总耗时129.445–150.808ms；无认证、不关闭证书校验、不跟随重定向、禁环境代理。[探针](artifacts/2026-09-27/singapore-node-readiness/sg-hk-public-probe.json)。这不是新加坡独立业务站或真实地区/运营商对照，不给主区评分。

## 下一步与恢复边界

用户已收到快照ID/限定实例角色的输入请求，随后询问角色提供方式；已交付[控制台步骤](2026-09-27-sg-iam-role-setup.md)及可直接粘贴的公开策略。用户已绑定，查询/快照创建实际通过，恢复点completed后才修改分区/FS。原无凭证状态及约8GiB根FS均为上面的历史基线，不能作为当前状态。

恢复点已核对为本次源卷、同区、扩容前生成。扩容前复读root挂载、NVMe serial、p1起始/EFI与boot分区布局；仅增加p1尾部，读回内核大小后扩XFS，核验布局/xfs_info/statvfs。XFS不能原地缩回；恢复依靠保留快照重建卷，不承诺缩容回退。本次只新增上述快照和完成系统分区/FS增长，未创建实例/数据卷、未安装包或重启。

这台4核/约8GiB主机可作为边缘/TURN准备对象；不是此前建议的完整候选主区8vCPU/32GiB+独立数据卷。正式边缘发布仍有NAT/端口/配额、远端secret文件、受限定向测试与可信源IP门禁，当前草案尚未作为具体生产部署批准。[边缘草案](../runbooks/singapore-edge-node.md)、[AWS资源清单](2026-09-27-aws-upgrade-resource-checklist.md)。
