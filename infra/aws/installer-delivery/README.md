# 安装包分发候选与维护权限

**当前状态（2026-09-28）：** 私有安装包桶、新OAC与分发已部署；Android2188网络测速下载页和更新URL已切换。实际分发为 `E30IR8IHK6PMXZ` / `d12fjr06o6tga5.cloudfront.net`，OAC为 `E6P1PEF2BA7OK`。TLS/Range/响应CORS/缓存读回通过；执行机浏览器的一次CDN样本超时后选香港直连，不声称所有设备的CDN响应已验证。初始化权限收紧需管理员全文替换同名策略，操作见末节；用户已确认全文替换，机器读回权限另见任务记录。

**历史初始化基线：** 2026-09-27首次预检使用账号 `218022113852` 的 `StarChatSgMaintenanceRole`；当时 `cloudfront:ListDistributions` 返回 AccessDenied、分发数量未知，本地候选尚未部署。用户之后附加补充策略并由管理员创建两项CloudFront资源，此拒绝已解决。角色没有IAM写入权限，不能自行提权。

目标是按用户实际网络选择快速且稳定的下载路径。CloudFront 会按网络延迟等因素选择 POP，但不能由此宣称它在每个用户网络中最快或最稳定；真实运营商和设备的长下载效果仍需反馈。本实现不使用 GPS、国家参数、GeoIP 或地理请求头。

## 管理员操作一：附加维护角色内联策略

1. 以已有 IAM 管理员身份登录 AWS 控制台，确认账号 `218022113852`。
2. IAM → Roles → `StarChatSgMaintenanceRole` → Permissions → Add permissions → Create inline policy。
3. 选择 JSON，将本目录 [bootstrap-policy.json](bootstrap-policy.json) 全文粘贴，检查资源及动作后以 `StarChatInstallerDeliveryBootstrap` 命名创建。
4. **保留角色现有策略，不替换或删除它们。** 此文件只增加本次候选所需权限；它不是角色的 permissions boundary，无法撤销其他既有策略的授权。
5. 完成后回报策略名称和完成状态即可。不要发送 Access Key、Secret Key、会话 Token、SSH 密钥或任何凭据。

| 范围 | 允许的动作和限界 |
| --- | --- |
| S3 创建 | 仅 `starchat-installers-218022113852-sg`，`s3:LocationConstraint=ap-southeast-1` |
| S3 配置 | 仅该桶的 policy、PublicAccessBlock、versioning、SSE-S3 encryption、tagging 及必要读取；ownership controls 只读 |
| S3 对象 | 仅 `downloads/*` 的 PutObject/GetObject，ListBucket 请求必须含 `downloads/` 前缀 |
| CloudFront 清点 | ListDistributions/ListOriginAccessControls；AWS 不支持资源 ARN 限界，必须 `Resource: *` |
| OAC | 创建单独一条 `Resource: *`；读取限于本账号 OAC ARN，未授权更新或删除 |
| 分发维护 | 本账号 `distribution/*`，仅已有 `Project=StarChatInstallerDelivery` 标签时 Get/GetConfig/ListTags/Update |

不增加 IAM、Route53、旧 media 桶、对象 ACL、账号级 PublicAccessBlock、分发/OAC/桶/对象删除权限。`HeadBucket` 需要不带 prefix 的 ListBucket，会被此补充策略拒绝；请用指定桶 GetBucketLocation、带 `--prefix downloads/` 的 ListObjectsV2、指定 APK 的 HeadObject 区分权限与存在状态，不将 AccessDenied 当成资源不存在。上传 81,505,310 bytes 已核验 APK 可用单次 `s3api put-object`，不需要扩大 multipart 清理权限。

S3 配置权限可以改变**这一个新桶**的安全配置，不能在 IAM 中证明每个提交的 policy 内容都安全。部署时必须检查四项 PublicAccessBlock=true、TLS-only policy、SSE-S3、versioning=Enabled，以及新桶默认的 ObjectOwnership=BucketOwnerEnforced；CloudFront OAC 只读 `downloads/*` 且 `AWS:SourceArn` 精确匹配本次分发。不授 PutBucketOwnershipControls，保留新桶默认禁用 ACL 的所有权设置。官方动作映射中 DeleteBucketEncryption/DeletePublicAccessBlock/DeleteBucketTagging 分别复用 PutEncryptionConfiguration/PutBucketPublicAccessBlock/PutBucketTagging，因此“无 Delete 动作”不等于禁止所有配置移除 API。禁止执行这些 API；部署后缩减配置写入授权，再保留必要对象读写与分发维护。

## 管理员操作二：一次性创建测速响应头策略与带标签分发

这份维护策略**不授予 CreateDistribution 或 TagResource**。IAM 的 `aws:RequestTag/Project` 只能限制要写入的标签值；给 `distribution/*` 授予 TagResource 后，维护角色也能给已有分发打上该标签，继而满足 UpdateDistribution 条件。它不能证明“只修改本次新建分发”。为避免这种标签提权路径，分发由有既有创建权限的管理员创建一次。

现有补充策略不授予 ResponseHeadersPolicy 创建、读取、更新或删除。由管理员自己的既有 AWS CLI/CloudShell 会话依次创建响应头策略和分发，**不需要用户再次修改已附加的维护策略**。

1. 维护角色准备独立桶和 OAC。用本地准备器的 `response-headers` 子命令生成完整 `CreateResponseHeadersPolicy` SDK 请求；候选文件保存于本任务 `docs/verification/artifacts/2026-09-27/installer-s3-cdn/` 下的部署子目录。准备器只生成候选，不代替云部署。
2. 管理员核对并将审核后的文件放入自己的 CLI/CloudShell 会话，命名为 `response-headers-request.json`。文件顶层必须是 `ResponseHeadersPolicyConfig`。核对 CORS：仅 `https://www.liuhetong888.com` Origin、GET/HEAD、允许 Range，ExposeHeaders 含 Content-Range/Content-Length/Accept-Ranges，AllowCredentials=false；不开放任意 Origin 或 cookies。执行：

   ```text
   aws cloudfront create-response-headers-policy --cli-input-json file://response-headers-request.json
   ```

   保存实际返回的 `ResponseHeadersPolicy.Id`、配置及 ETag，先检查已有同名策略及前态，重试不能重复创建。AWS managed SimpleCORS 不暴露 Content-Range，不能直接替代这份测速响应头策略；S3 源不转发 Origin，因此由 CloudFront 给 viewer 响应添加所需 CORS 头。
3. 本地准备器 `distribution` 子命令使用实际 OAC ID、实际 ResponseHeadersPolicy ID 和本次唯一 CallerReference 生成完整分发请求。参数为 `--oac-id`、`--response-headers-policy-id`、`--caller-reference`。管理员核对候选：新桶 regional endpoint + OAC 是主源，现有香港版本化 APK 是回退源；GET/HEAD、HTTPS、PriceClass_All、无 cookies/query/含 IP 访问日志；实际响应头策略 ID 已绑定到版本化 APK behavior；不使用旧 media 桶、不改 DNS。
4. 将完整请求命名为 `distribution-request.json`。使用管理员自己的 AWS CLI/CloudShell 会话执行一次创建：

   ```text
   aws cloudfront create-distribution-with-tags --cli-input-json file://distribution-request.json
   ```

   生成器输出的是完整 SDK request：顶层 `DistributionConfigWithTags`，该字段内含实际生成的 `DistributionConfig` 和 `Tags.Items=[{"Key":"Project","Value":"StarChatInstallerDelivery"}]`。必须使用 `--cli-input-json` 读取完整请求，不将外层请求传给仅接收内层结构的 `--distribution-config-with-tags`。`CallerReference` 要沿用该部署的唯一值；先清点已有资源并保存前态，重试不得随意换值重复创建。
5. 保存返回的实际分发 ID、ARN、域名、OAC ID 和响应头策略 ID，交给维护流程。管理员保存响应头配置读回证据，因为维护角色没有读取此策略的权限。CloudFront 是全球服务；桶在 `ap-southeast-1` 并不把客户端固定到新加坡 POP。

管理员自身须有 `cloudfront:CreateResponseHeadersPolicy`（不支持资源 ARN，`Resource: *`）及必要的本账号响应头策略读取权限；分发创建须有 `cloudfront:CreateDistribution`（不支持资源 ARN，`Resource: *`，可以要求 `aws:RequestTag/Project=StarChatInstallerDelivery` 与仅 `Project` TagKeys）及 `cloudfront:TagResource`（本账号 distribution ARN）。不要求维护角色能修改已有响应头策略。`CreateDistributionWithTags` 是 API 操作名，不能作为同名 IAM 动作代替这两项授权。不能给创建时的 TagResource 强加“已经存在 Project 标签”条件，否则新资源可能无法通过授权；也不能在失败时直接授予 `cloudfront:*`。本文不自动附加管理员策略，不请求长期凭据。

## 创建后的精确 ID 第二阶段

拿到实际资源 ID 后，再编辑**本次新增的内联策略**：删除 `CreateOnlyInstallerBucketInSingapore` 和 `BootstrapCreateOriginAccessControl` 两条；将 `ReadAccountOriginAccessControls.Resource` 换成本次确切 OAC ARN，将 `MaintainOnlyTaggedInstallerDistributions.Resource` 换成本次确切分发 ARN，保留 Project ResourceTag 条件。按维护需求移除已完成初始化的 S3 配置写权限，不动原角色其他策略。不要保留一个与更窄策略并存的 bootstrap Allow，IAM Allow 会取并集。

策略到位后重新做只读身份/权限/资源预检；仍遇 AccessDenied 时记录实际动作、ARN、显式 deny/permissions boundary/SCP 等上下文并停在依赖步骤，不放宽到其他桶或其他分发。未完成云部署、APK 上传及网络/缓存/Range/失败回退验收前，不切网页或更新设置。现有香港下载入口继续作为可用回退。

## 本地验证与官方依据

```text
py -3.12 -m pytest tests/infra/test_installer_delivery_policy.py -q
```

测试检查补充策略的动作、ARN、prefix、地区及已有标签限界，不等于 AWS IAM simulator 结果，也不证明实际角色的所有权限。真实 red/green 及输入 SHA256 记录在 `docs/verification/artifacts/2026-09-27/installer-s3-cdn/iam/`。

- [CloudFront IAM 动作、API 映射及条件](https://docs.aws.amazon.com/service-authorization/latest/reference/list_cloudfront.html)：CreateDistribution/TagResource、OAC 创建及资源标签支持。
- [S3 IAM 动作与条件](https://docs.aws.amazon.com/service-authorization/latest/reference/list_s3.html)：CreateBucket LocationConstraint、ListBucket prefix、Get/Put 与配置移除操作的动作映射。
- [CloudFront 网络与 POP 选择](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/HowCloudFrontWorks.html)。
- [OAC 的 S3 SourceArn 限界](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html)。

官方表于 2026-09-27 查阅；候选不包含实际分发/OAC ID，不能把示例或未知 ID 当部署事实。

## 2026-09-28 初始化后的精确资源维护策略候选

[maintenance-policy.json](maintenance-policy.json) 是本次初始化后收紧权限的**未应用候选**，不修改已附加的 bootstrap 文件。实际安装包桶为 `starchat-installers-218022113852-sg`，分发为 `E30IR8IHK6PMXZ`（`d12fjr06o6tga5.cloudfront.net`），OAC 为 `E6P1PEF2BA7OK`。本节的实际 ID 取代上文初始化候选中的未知 ID；CloudFront、S3 和入口发布状态仍以本次任务记录为准。

候选移除 CreateBucket、CreateOriginAccessControl、初始化用 PutEncryptionConfiguration/PutBucketVersioning/PutBucketPublicAccessBlock/PutBucketTagging，以及其他 OAC 的读取、所有其他分发的读取与更新授权。保留指定桶配置只读、PutBucketPolicy、`downloads/*` 的 GetObject/PutObject 和带相同 prefix 的 ListBucket；CloudFront 读/更新只限上述精确分发 ARN 并要求原有 Project 标签，OAC 仅精确 ARN 只读。唯一 `Resource: *` 为 ListDistributions：官方 IAM 动作表不支持为该清点动作绑定分发 ARN，它只提供账号分发清点，不能据此修改其他分发。本候选不授予 ResponseHeadersPolicy 读取或修改；所需读回继续由管理员保存，不为此扩大角色权限。

以下操作由已有 IAM 管理员执行，维护角色不能自行修改 IAM。**替换 `StarChatInstallerDeliveryBootstrap` 同名策略全文，而非额外附加一份策略**：并存的 bootstrap Allow 会继续生效，不能达到本次收紧目标。

1. 先保存 IAM → Roles → `StarChatSgMaintenanceRole` → Permissions 中现有 `StarChatInstallerDeliveryBootstrap` 的 JSON，核对账号 `218022113852`、实际分发/OAC/桶 ID 及 Project 标签。保留角色其他所有策略。
2. 打开该同名内联策略的 Edit/JSON，将全文替换为 [maintenance-policy.json](maintenance-policy.json)，Review 后保存。无需删除再新建策略，也不添加其他 IAM 权限。
3. 若使用管理员既有 AWS CLI 会话，可将审核后的 JSON 放在 CloudShell 当前目录，执行下面一条替换操作。此命令是管理员操作说明，本任务未执行它：

   ```text
   aws iam put-role-policy --role-name StarChatSgMaintenanceRole --policy-name StarChatInstallerDeliveryBootstrap --policy-document file://maintenance-policy.json
   ```

4. 管理员通过控制台或 `aws iam get-role-policy --role-name StarChatSgMaintenanceRole --policy-name StarChatInstallerDeliveryBootstrap --query PolicyDocument --output json` 读回，比较完整候选；只回报完成状态和策略名，不发送凭据。维护流程再验证精确资源读取、带 prefix 清点及匿名 S3 拒绝，检查桶四项 PublicAccessBlock、SSE-S3、版本化和 TLS-only/OAC policy 仍符合要求。不要通过生产写入其他分发、关闭安全配置或删除资源来验证拒绝路径。

PutBucketPolicy 用于以后发布新版本时扩展同一分发 `AWS:SourceArn` 下允许读取的不可变 APK key；它仍有修改整个指定桶 policy 的能力。IAM 不能验证提交的 policy JSON 是否只做这项扩展，提交前必须保留 TLS-only deny，并将 CloudFront allow 的 principal、SourceArn 和实际版本 key 与已审查配置逐项比较。对象 PutObject 同样不是“禁止覆盖”的保证，上传仍须使用已审查的版本路径、SHA/bytes 校验及不覆盖不同内容的门禁。本候选没有 delete、ACL、IAM、Route53、媒体桶、CloudFront 标签写入或 OAC 修改权限。

截至本候选生成，**尚未替换实际角色策略，不能称生产权限已收紧**。这份补充策略不是 permissions boundary；角色其他策略、SCP/boundary 和资源策略共同决定有效权限，局部测试也不能证明完整角色没有其他授权。

本地测试（不连接 AWS）：

```text
py -3.12 -m pytest tests/infra/test_installer_maintenance_policy.py -q
```

官方依据于 2026-09-28 重查：[CloudFront IAM 资源与条件表](https://docs.aws.amazon.com/service-authorization/latest/reference/list_cloudfront.html)确认 distribution/origin-access-control 精确 ARN 支持以及 ListDistributions 的全局清点范围；[S3 IAM 表](https://docs.aws.amazon.com/service-authorization/latest/reference/list_s3.html)用于动作、桶/对象和 prefix 限界。真实红绿和候选 SHA 记录在 `docs/verification/artifacts/2026-09-27/installer-s3-cdn/maintenance-iam/`。
