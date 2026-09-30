# 为新加坡EC2绑定临时快照角色

角色绑定给EC2实例即可，助手继续经已配置SSH/jumper在实例内使用AWS CLI；不需要发送Access Key、Secret Key或元数据中的临时凭证。此角色只服务于扩容前备份，不是整个AWS架构管理权限。

## 控制台操作

1. 打开IAM → 策略（Policies）→ 创建策略 → JSON，粘贴[权限文件](artifacts/2026-09-27/singapore-node-readiness/ec2-snapshot-permissions.json)的完整内容。策略名建议`StarChatSgRootSnapshotPolicy`。无需修改账号ID或其它占位符。
2. 打开IAM → 角色（Roles）→ 创建角色。可信实体选AWS服务，服务/使用案例选EC2；下一步勾选刚创建的策略，角色名建议`StarChatSgMaintenanceRole`。选择EC2使用案例会创建相应instance profile；其信任关系应为[EC2信任策略](artifacts/2026-09-27/singapore-node-readiness/ec2-role-trust.json)。[AWS角色创建文档](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-service.html)
3. 回到EC2控制台的新加坡区域ap-southeast-1 → 实例 → 选择`i-035b46916e4cf43eb` → 操作（Actions）→ 安全（Security）→ 修改IAM角色（Modify IAM role）。选择`StarChatSgMaintenanceRole`并更新。运行中的实例可绑定角色，无需为此重启。[AWS绑定步骤](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/attach-iam-role.html)
4. 回复“已绑定”即可；可附角色名，不必发送ARN或密钥。助手先复验卷/快照查询权限，再创建目标卷备份并等待completed，之后执行分区/XFS扩容和容量读回。

一个EC2只能关联一个instance profile；若页面已有角色，保留原权限，优先把这份有限策略加到原角色，不直接替换正在被其它用途使用的角色。最终以实例页面和现场AWS调用读回为准，不能仅凭角色已创建判断可用。

## 权限边界

- 只允许在ap-southeast-1查询卷和快照元数据。这两个Describe API不支持按单卷ARN限制，所以使用Resource="*"并限区域；助手的调用仍只过滤所交接的卷/快照，不宣称账号级查询权已被限制到一个卷。
- 创建快照的源卷固定为`vol-019dd3dc00b9a08bd`；volume ARN账号位使用通配以便直接粘贴，但区域与卷ID固定。新snapshot尚无ID，按AWS示例另授权snapshot创建资源，必须同时带两项固定标签：`StarChatPurpose=sg-root-expansion`、`StarChatInstance=i-035b46916e4cf43eb`。
- CreateTags仅在CreateSnapshot创建时有效，不能给既有快照/卷任意打标。以上为按[AWS EBS快照权限示例](https://docs.aws.amazon.com/ebs/latest/userguide/security_iam_id-based-policy-examples.html)收窄的任务策略；[EC2授权参考](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html)说明动作及资源约束。
- 不授予创建实例、改安全组、修改/删除卷、删快照或任何IAM写入；无需AdministratorAccess或AmazonEC2FullAccess。本地JSON已作结构及范围检查，尚未在用户账号运行IAM策略验证或真实快照创建，SCP/permissions boundary/组织策略仍可能限制有效权限。
- 卷加密状态目前无法查询；若后续读回使用自管KMS且实际创建要求额外权限，再针对该key补充，不提前授予KMS通配权限。

恢复点就绪前未修改分区或文件系统。仅完成角色创建/绑定不批准边缘生产服务、DNS、TURN候选或主区切换；这些仍须依据各自具体方案推进。
