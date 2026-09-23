# 网络优化采购与恢复记录

更新时间：2026-09-23 17:29 +08:00。用户已授权优先媒体分流、区域TURN、多AZ和大陆线路测试，随后明确尚未购买AWS并要求推荐购买配置。当前阶段为采购选型；没有AWS身份、预算或真实运营商测点。没有创建云资源或修改生产。

工作树 .worktrees/network-delivery，分支 codex/network-delivery，基线f43ec78a。文件所有权：本任务新增设计/计划/采购记录与network-delivery证据目录；没有产品源码更改。前轮线上只读结论见../../verification/2026-09-23-network-architecture.md。

## 首批推荐

- AWS全球账号，香港ap-east-1和新加坡ap-southeast-1各1台c6i.large（2vCPU/4GiB），Ubuntu Server 24.04 LTS x86_64官方镜像，30GiB gp3加密盘，各1个Elastic IP，Linux按需计费。用于独立HTTPS/UDP线路验证和后续TURN，不承载完整生产栈。
- 先运行3–7天，覆盖大陆电信/联通/移动与实际东南亚国家移动/宽带。AWS两台机器是目标节点，不能替代大陆用户测点。
- 1个私有S3 bucket与1个CloudFront分发用于公开合成测试文件/安装包试点；首轮桶可放香港，确定主区后最终同区域部署。不开公开桶，不上传私密聊天附件。域名先用分配域名，不切线上。
- 按需购买，无Spot、无长约。GA仅测试阶段创建，停用仍收费，试验后不用需删除。首批不创建RDS/ALB/NAT或跨区数据库复制，待主区确定后按下方部署。

## 正式部署扩容目标

主区2台m7i.xlarge（每台4vCPU/16GiB），不同AZ，每台80GiB gp3；1套跨AZ ALB；业务与Matrix PostgreSQL保持分离的数据库/角色边界，实例合并与否按测试决定，各必要数据域具有Multi-AZ恢复；Redis也做跨AZ恢复；香港/新加坡试点机可继续作TURN。不能把两台应用服务器当作数据库/媒体/主角色都已HA。完整部署数量和数据库规格取决于混合负载验证，不宣称1000在线必然由某机型保证。

## 费用口径

EC2计算、EBS、公网IPv4、互联网出口、CDN、S3请求、跨AZ传输分别计算；视频出口尤其不能按人数推算。GA官方固定价0.025美元/小时，730小时约18.25美元，但另有流量溢价、正常传输与公网IPv4费用。未取得两区域实例实时报价，不提供伪精确总月价。预算以AWS Calculator所在区域当前价格和明确GB假设评审，正式采购仍需预算输入。

## 实施与验证状态

- 架构方向与采购次序已形成；[设计](../../superpowers/specs/2026-09-23-network-delivery-design.md)、[计划](../../superpowers/plans/2026-09-23-network-delivery.md)。计划是待执行清单，不是已实现模板或部署。
- infra基线：py -3.12 -m pytest tests/infra -q，144 passed in15.44s，exit0；仅基线，不证明AWS资源可用。日志docs/verification/artifacts/2026-09-23/network-delivery/infra-baseline.log。
- AWS/CDN/TURN模板和采样器尚未实现，真实三网测试尚未执行，生产没有切流。
- 阶段起点精确时间未记录；工作树准备与基线已完成，17:29进入采购输入等待。没有后台运行进程或新建云资源。
- 下一步：用户创建AWS账号并确认试点预算，通过SSO/Role提供接入后核对账号区域/配额/费用，按计划先做可审查模板与测试再创建试点。无需用户发送长期密钥。真实大陆/东南亚测点同时确认。

官方依据：[实例区域支持](https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-regions.html)、[C6i配置](https://aws.amazon.com/ec2/instance-types/c6i/)、[M7i配置](https://aws.amazon.com/ec2/instance-types/m7i/)、[按需计费](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-on-demand-instances.html)、[GA价格](https://aws.amazon.com/global-accelerator/pricing/)、[VPC费用](https://aws.amazon.com/vpc/pricing/)。
