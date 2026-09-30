# 扩盘、S3和RDS的成本判断

2026-09-27核对AWS官方新加坡区域价格目录；美元、按需、730小时/月估算，不含税、额外备份/性能/网络/突发积分。不将示例实例规格视为业务容量结论。

| 配置 | 月费用 | 适用问题 |
|---|---:|---|
| EC2 gp3 100GB | $9.60 | 服务器本地容量 |
| EC2 gp3 250GB | $24.00 | 当前40→250GB增加$20.16/月 |
| S3 Standard 100GB | $2.50，仅存储 | 图片/视频/密文附件对象化 |
| S3 Standard 250GB | $6.25，仅存储 | 同上 |
| RDS PostgreSQL t4g.medium单AZ＋100GB gp3 | $88.26 | 2vCPU/4GiB数据库隔离/托管备份 |
| 同上Multi-AZ含备用 | $175.79 | 增加数据库自动故障切换 |
| RDS PostgreSQL m6g.large单AZ＋100GB gp3 | $175.13 | 2vCPU/8GiB，非容量保证 |
| 同上Multi-AZ含备用 | $349.53 | 同上故障切换 |

S3 10000次PUT/LIST＋100万次GET约$0.45。TURN和S3新加坡首档互联网出网$0.12/GB；账户全服务/区域共享免费100GB若仍完整可用，1000GB出网约$108，额度耗尽约$120。香港主机若为AWS外部资源，从S3读取算互联网出网，不能误套同区域EC2↔S3免费；香港再发送客户端仍需计当地供应商带宽。AWS新加坡→AWS香港跨区域$0.09/GB，不适用于本次外部香港主机。NAT等中间服务可能另收费。

## 现场结论

香港根盘218G、用67G、可用140G、使用率33%；业务媒体58M、Matrix媒体788M、业务PG目录262M、MatrixPG目录193M。磁盘目录大小不是数据库逻辑数据大小，单位为du/df当次输出。新加坡40GiB根盘已扩容，edge不存业务媒体/数据库，暂不建议再扩至250GB。

香港约8GB内存，可用约528MiB、swap约2GB全占；当次memory pressure avg10/60/300均0，load约0.4–0.5，不能仅据swap占用断言正在内存抖动。29个容器含其他项目与测试PG，业务数据库分别约212.5/320.6MiB的容器内存采样；未关闭其他任务资源。一次采样不证明峰值压力，购买数据库前应记录CPU/内存、磁盘延迟/慢查询/连接等待及恢复目标。

因此：只解决容量，扩gp3明显比买RDS便宜；媒体存储用S3，RDS不存照片视频来替代它。当前磁盘富余，先完成S3/中继与观测，保留现有PostgreSQL；若持续内存压力，再考虑增加RAM/经所属任务确认回收测试资源。需要数据库自动故障切换、托管备份/恢复或明确DB瓶颈时，再评估RDS同主业务区域的独立项目，不能把DB放新加坡而业务API仍香港来消除本次容量问题。

21:30复核SG edge/TURN均健康、只读根FS、无Docker持久volume；根FS约39.93GiB、可用36.57GiB。21:21有限S3回填及随后覆盖审计已通过，本地旧媒体仍保留，不立即释放源盘空间。香港20:55迁移期间memory pressure avg10=0、avg60/300约0.07/0.04，四业务/媒体服务无重启；这仍是采样，不能据此承诺高峰容量或用新增RDS解决下载长尾。当前不新增磁盘或RDS购买，费用判断和流量边界保持。

## 官方证据

- [EBS价格](https://aws.amazon.com/ebs/pricing/)；[新加坡EC2/EBS目录](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/ap-southeast-1/index.csv)，发布2026-09-25T17:45:21Z，gp3 SKU X8SY8CJFS8WV7VQN=$0.096/GB-month。
- [S3价格](https://aws.amazon.com/s3/pricing/)；[新加坡S3目录](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonS3/current/ap-southeast-1/index.json)，发布2026-09-26，Standard=$0.025/GB-month；PUT/LIST=$0.005/千次，GET=$0.0004/千次。
- [RDS PostgreSQL价格](https://aws.amazon.com/rds/postgresql/pricing/)；[新加坡RDS目录](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/ap-southeast-1/index.json)，发布2026-09-24，t4g.medium单/双AZ=$0.102/$0.203每小时，m6g.large=$0.221/$0.441；RDS gp3=$0.138/$0.276每GB月。t4g额外CPU积分=$0.075/vCPU小时。
- [EC2出网与共享免费额度](https://aws.amazon.com/ec2/pricing/on-demand/)；[新加坡流量目录](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSDataTransfer/current/ap-southeast-1/index.json)，发布2026-09-16；[同区与跨区网络计费](https://aws.amazon.com/about-aws/global-infrastructure/global-network/faqs/)。
- 价格目录由子代理通过SG实例HTTPS只读访问解析，未创建资源或更改系统；实时价格为当次快照。现场[资源采样](artifacts/2026-09-27/edge-s3-deployment/hk-resources.log)。
