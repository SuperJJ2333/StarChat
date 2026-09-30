# AWS区域架构升级资源清单

网络诊断兼容接收端发布使用香港既有资源，不需要新AWS设备。本清单是分阶段资源建议；后续用户已交接SG40GiB卷并授权完成Linux分区/XFS扩容，具体见下条。未购买实例、建边缘服务或切换主区；下表香港容量仍来自2026-09-26只读快照，不把磁盘用量当媒体/数据库净大小。

2026-09-27新增[实例交接/扩容核验](2026-09-27-singapore-node-readiness.md)：SG主机c5.xlarge/4CPU/约7.50GiB，目标gp3裸卷40GiB。用户绑定有限角色后，完成快照`snap-0f0329f5092ee868b`，14:23在线扩p1/XFS，14:27复核根FS39.93GiB/可用38.07GiB、未重启、启动分区不变。原卷未加密属性保持；无业务数据迁移。角色流程见[步骤](2026-09-27-sg-iam-role-setup.md)。下表边缘根盘30–40GiB容量准备已满足，边缘服务部署仍另行推进。

| 阶段 | 建议准备 | 工程边界 |
| --- | --- | --- |
| 新加坡边缘/TURN | 复用现有4逻辑CPU/约8GiB/x86_64机器，根盘从8GiB扩到30–40GiB gp3 | 只放系统、镜像和有界日志；这是余量建议，不是AWS最低硬规格。边缘不是独立业务主区 |
| 完整候选主区 | 至少8vCPU/16GiB/x86_64非CPU积分型，例如C6i.2xlarge；更宽裕的混合业务起点M6i.2xlarge，8vCPU/32GiB | 容量须通过实际负载验证，不能据规格保证在线人数。地区对照应两地相同SKU/镜像/数据与负载 |
| 候选主区存储 | 根40–60GiB，独立加密gp3数据卷；保守起点250GiB，按真实数据、增长、升级和恢复余量调整 | 香港快照根盘约217GiB、已用64GiB，其中混有OS/镜像/其它服务，不能等同业务持久数据 |
| 正式高可用 | 应用跨AZ、正确的Synapse worker拆分、同区私网PostgreSQL/Redis、备份与恢复演练 | 单台机器不能替代高可用。RDS/S3/区域/备份策略单独设计；ADR0086仍待批准 |

官方实例规格：[计算优化C6i](https://docs.aws.amazon.com/ec2/latest/instancetypes/co.html)、[通用M6i](https://docs.aws.amazon.com/ec2/latest/instancetypes/gp.html)。香港ap-east-1与新加坡ap-southeast-1支持情况见[区域支持表](https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-regions.html)，具体AZ、账户配额和当时可用容量还要按账户核对。保持x86_64并核验现有所有容器架构后再选型号，不直接换Graviton。

交接只需区域/AZ、实例ID、型号、AMI与架构、EBS卷类型/容量、VPC/子网/安全组、固定公网IP和SSH用户名。访问继续经现有jumper，公钥授权和主机指纹在本机配置，私钥不写聊天或仓库。若需要代管AWS资源操作，提供限定目标区域/资源的临时IAM角色；目前SSH发布不需要AWS账户root凭据。EC2未来访问S3使用实例角色并限制桶/prefix。[IAM实践](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)

核实公网地址是否为Elastic IP；新关联可能改变旧公网地址，EIP属于单一区域。[EIP说明](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/elastic-ip-addresses-eip.html)。SSH22只允许jumper出口；业务数据库5432与Redis6379只走应用私网来源。边缘80/443在测试阶段仅授权测点开放；TURN3478与49160–49200 UDP等依独立部署方案精确开放，5349/TLS另验。[安全组原则](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html)

扩盘先保留快照，再调整EBS和Linux分区/文件系统，最后读回容量；仅控制台改卷大小不算完成。[Linux扩盘流程](https://docs.aws.amazon.com/ebs/latest/userguide/recognize-expanded-volume-linux.html)。未报价或锁定采购；先完成当前接收发布，再按测量与恢复方案逐步验证边缘/候选主区。
