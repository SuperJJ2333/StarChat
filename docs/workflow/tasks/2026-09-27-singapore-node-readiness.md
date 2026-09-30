# 新加坡实例交接、根卷扩容与部署准备

## 恢复入口

- 用户于2026-09-27交接新加坡EC2/40GiB卷/现有SSH访问，随后询问如何提供IAM角色。执行设备核验和扩容准备，不把交设备当作DNS/边缘服务上线/主区迁移批准。
- 依据：[AWS资源清单](../../verification/2026-09-27-aws-upgrade-resource-checklist.md)、[已批准测量设计](../../superpowers/specs/2026-09-26-regional-measurement-design.md)、[生产工作流](../../runbooks/admin-production-workflow.md)。
- 状态：用户回复角色已绑定后，现场权限/快照/在线扩容完成；最终2026-09-27 14:27+08复核通过。本批设备根盘扩容完成，边缘/主区生产化未执行。
- 所有权：本任务/验证报告、SG IAM交接文件、新日期工件；只更新共享索引顶部及资源/边缘文档实时条目，不改infra/业务代码或生产配置。
- 任务起始主目录HEAD b9eca8a419614112b085439445b7fd031027a740，保留全部其它任务输入。仓库仅文档/操作证据变更，未创建新工作树/运行业务全回归；操作脚本保护10测与真实SG验证已执行。
- 下一步：保留快照与远端0700布局证据，按具体边缘方案处理安全组/NAT/secret文件/可信源IP门禁；设备仍4CPU/约8GiB，不把扩盘当完整主区升级。角色交接见[步骤](../../verification/2026-09-27-sg-iam-role-setup.md)，已执行[扩容计划](../../superpowers/plans/2026-09-27-sg-root-expansion.md)。

## 验收台账

| ID | 预期 | 实测/状态 | 缺口 |
| --- | --- | --- | --- |
| SG01 | SSH与实例/卷身份匹配 | PASS：严格主机校验经jumper、IMDSv2/serial匹配 | 不读取IAM凭证 |
| SG02 | 40GiB到分区与FS | PASS：completed快照后在线增长，根FS39.93GiB/可用38.07GiB | 保留快照，未执行启动恢复演练 |
| SG03 | 资源/已运行服务 | PASS：c5.xlarge/4CPU/约7.50GiB，gp3/40GiB/Encrypted=false读回，Docker未装 | EIP/安全组尚未核实；原卷属性保留 |
| SG04 | SG→HK公开HTTPS | PASS：5/5 API200与健康JSON，证书验证保留 | 不是用户地区/两地主区对照 |
| SG05 | 最小IAM交接 | PASS：绑定后Describe与带固定标签CreateSnapshot均实际通过 | 此前无凭证/253为历史；未授予额外IAM操作 |
| SG06 | 边缘/主区生产化 | 未执行 | 具体部署方案/门禁单独推进，未变DNS/香港/TURN |

## 证据与计时

全部公共证据在`docs/verification/artifacts/2026-09-27/singapore-node-readiness/`；私钥内容不读/不上传。inventory-result、expansion-preflight-result、public-probe-result记录命令实际起止、退出码与脚本SHA，UTC样本时间转换+08为12:19:42/12:21:26/12:23:21起；不推算主动调查工时。首条SSH工具1.62秒退出0。详情见[验证报告](../../verification/2026-09-27-singapore-node-readiness.md)。

| 阶段（2026-09-27 +08） | 开始 | 结束/观察点 | 结果与来源 |
| --- | --- | --- | --- |
| 角色绑定后复核 | 14:08:10 | 14:08:14 | exit0，role-bound-preflight-result.json |
| 备份准备/创建快照 | 14:13:47 | 14:13:52 | exit0，snapshot-create-result.json；仅本卷snapshot新增 |
| AWS快照等待 | 14:13:49创建 | 14:21:09观察已完成 | 非精确完成时刻；snapshot-status.json为首次completed读回 |
| 分区/XFS增长 | 14:23:40 | 14:23:44 | exit0，expansion-result.json |
| 新SSH连接复核 | 14:27:22 | 14:27:25 | exit0，verify-result.json |

## 交接与回退

快照`snap-0f0329f5092ee868b`为completed/100%；仅根分区尾部/XFS增长，EFI/BIOS分区不变、boot_id不变、sshd active、内核磁盘/XFS错误0。远端0700目录`/opt/starchat/maintenance/sg-root-expansion-20260927`保存布局/快照ID/操作意图与结果，无凭证。无包安装、容器启动、隧道或遗留长运行命令。XFS增长不支持原地缩回，恢复基于扩容前EBS快照，未验证从快照启动。角色仅用于本次备份，完成后按用户需要移除，不能替换其它已有生产角色权限。
