# 边缘与媒体存储部署所需 AWS 输入

**2026-09-27 18:12+08 当前：用户输入均已验证到位，无需再提供云端配置。** 下文14:52/16:21是历史调查。实例i-035b46916e4cf43eb已绑定EIP18.143.207.225，sg域名一致；SuperJJ STS与实际两个媒体前缀CRUD/严格404通过，限定秘密写入/读回通过。秘密值未进入聊天、本机或仓库。当前缺口属于部署验收：TURN拒绝策略、香港实际S3延迟与存量迁移门禁。见[任务](../workflow/tasks/2026-09-27-edge-s3-deployment.md)。

2026-09-27 14:52+08 实测：实例角色 StarChatSgMaintenanceRole 可完成快照操作，但 DescribeInstances/Addresses/SecurityGroups、S3 ListBuckets、Route53 查询均 AccessDenied。实例安全组经 IMDSv2 核对为 sg-057b9653a9a140598，账户 218022113852；这些不是凭据。

用户本轮已明确授权部署边缘/TURN/S3，无需再次确认部署。此处仅缺云端实际权限与服务身份，SSH 权限不能替代 AWS API 权限。

1. 将 [maintenance-policy.json](artifacts/2026-09-27/edge-s3-deployment/maintenance-policy.json) 作为附加内联策略绑定到既有实例角色，保留快照策略。它只允许查询新加坡网络、给当前一个安全组增加入站、配置两个精确候选桶名、操作业务/Matrix前缀、读取一个指定秘密。最终只选一个生产桶；另一名称仅预留区域选址，不代表双写。不给 IAM 管理、数据库购买、删除桶、修改其他安全组或DNS权限。
2. 在域名实际 DNS 托管处添加 sg.liuhetong888.com 的 A 记录 13.229.60.153，DNS-only，TTL300；不要修改主业务域名。若已经存在，告知即可。弹性IP绑定尚缺读取权限，正式添加URI前必须确认IP稳定；若非EIP，需补固定IP方案。
3. 香港主机非 EC2，不能直接长期使用新加坡实例的临时角色凭据。创建独立程序身份（无控制台密码），只赋予 [hk-media-identity-policy.json](artifacts/2026-09-27/edge-s3-deployment/hk-media-identity-policy.json)。在新加坡 Secrets Manager 创建名为 `starchat/production/media-s3` 的秘密，用自有账户控制台存两个字段 `AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY`。不要将值发到聊天、仓库或本机文件。部署时只从实例角色获取并经加密服务器通道注入香港受保护配置，输出仅含存在/权限状态。若已经有可续期服务身份可用，优先复用并告知其机制。

秘密创建、访问、出网均有 AWS 费用。程序身份必须安排密钥轮换；启动读回/迁移/回退均不得依赖过期的 EC2 临时凭据。S3后端仍使用SDK默认凭据链，不在代码内嵌密钥。

放行计划：TCP443供定向边缘TLS测试、UDP/TCP3478供TURN、UDP49160–49200中继；不放行数据库、8080、明文CLI。安全组读回和NACL/路由检查先于实际变更。

策略中的ListBucket允许枚举两个精确候选桶（不是列出账户所有桶）；Get/Put/DeleteObject仍只限business/*、synapse/*。AWS对不存在对象的HEAD需ListBucket权限才返回404，否则403；为保证缺失与无权限严格区分，枚举权限不附加仅适用于List请求的prefix条件。存储代码本身只列出已校验的前缀。参见[AWS HeadObject权限](https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadObject.html)。原调查ListBuckets/Route53被拒并不需要解除；正确的最小策略有意不授予这些账户级列表权限。部署会对精确桶、前缀、fence不存在时404再联测。

下一步：权限到位后读取现状，配置私有SSE-S3/TLS-only桶及防火墙，逐对象校验迁移并发布；没有权限时不能声称服务已上线。

## 2026-09-27 16:21+08 实际到位与缺项

用户已绑定maintenance策略、添加DNS并创建秘密。实例/安全组/NACL/路由查询通过；DNS精确解析
13.229.60.153，IGW默认路由及NACL允许。ListBuckets/Route53拒绝是有意最小权限，勿扩大。
EIP查询返回空，当前是自动分配公网IP；正式TURN候选需要用户关联弹性IP并同步DNS。
秘密Get通过、所需两个字段存在且无session token；STS返回 `InvalidClientTokenId`，服务身份尚不可用。
不保留或输出字段值。用户须在控制台修正同一已启用程序身份的访问密钥和限定策略。

维护策略已补 `PutSecretValue`，仅限同一个指定秘密ARN；用户需同步此修订。它用于服务器间安全
继承香港现有TURN密钥到秘密管理，保留AWS字段，不把TURN密钥经聊天或本机文件传输。
该项是infra/AGENTS.md生产密钥必须源于秘密管理的明确要求，不是重复部署授权。

16:24+08单个新加坡私有桶已创建并读回：SSE-S3 AES256、四项公有阻止、TLS-only、无lifecycle、
版本化未启用。只创建SG桶，没有HK双写或生产对象迁移。香港实际serving路径p95/费用门禁仍须完成。

## 2026-09-27 19:10+08 用户输入已闭环

EIP18.143.207.225绑定i-035b46916e4cf43eb，sg域名一致；SuperJJ STS确认账户及IAM身份，HK经受保护SDK文件实际两个前缀CRUD/严格404通过。限定秘密写入已生效，原HK TURN密钥经原生SSH管道继承并读回，AWS字段保留。新加坡固定TURN4.13.1公网双向中继及配额验收通过，香港已公布两个SG候选；新EIP定向TLS再次通过。

当前无需用户再提供AWS设备、IAM权限或秘密值。剩余工作是已授权的兼容服务发布、逐对象迁移和生产验收。旧章节的自动公网IP和InvalidClientTokenId只作历史记录。主业务域名继续指向香港，S3桶只有新加坡一个，不购买数据库或额外磁盘。
