# 续期防复发措施已安装

> 2026-09-26 源码交接：下文“已安装、回填但未提交/推送”为 2026-09-24 的历史状态。本次将原已审查的五个脚本、测试和配套文档纳入集成候选；未重装生产、重发邮件或重启业务容器。生产实时状态须另行读取，历史验收不替代实时检查。

2026-09-24 +08:00，用户授权三项优先措施，并追加指定复用backend报警邮件。实现及生产安装完成，不改变业务认证策略，无数据库迁移、无业务容器重启。

## 验收结果

| 要求 | 实现与现场证据 |
| --- | --- |
| 最终镜像协议测试 | 当前API 38ed2bec、worker 237162be各通过9组真实ASGI协议检查；容器无网络、无生产配置，独立SQLite，验证轮换/重试/重放/退出/管理员域与cookie边界。 |
| 兼容回退限制 | 旧API 8ca29621及旧rollback清单被拒绝。现用release.py deploy/rollback调用统一门禁；要求API和worker双角色完整、实际Compose镜像与清单一致，全部通过后冻结配置，切换严格使用冻结路径。实际rollback入口已证明在切换前拒绝旧镜像。 |
| 续期异常报警 | 每分钟检查5分钟窗口，协议异常、422/5xx/高失败率及监控自身失败进入告警；去重、恢复、失败保留与有界重试。复用worker SMTP与既有告警收件人。单封“通道验证”邮件返回SMTP_ACCEPTED，未声称收件箱确认。 |
| 生产安全 | 安装→恢复→重复恢复→再安装演练通过；24个运行容器的ID、镜像与启动时间全部不变。timer active，service Result=success、ExecMainStatus=0，当前active为空、delivery_error=false。 |

代码已从`codex/refresh-restore`逐文件回填主目录，保留其他未提交修改。主目录新增5个运维脚本及1个测试文件，哈希清单见证据目录。没有重建生产镜像或移动APK，也没有Git提交/推送。

## 证据与审查

`docs/verification/artifacts/2026-09-24/refresh-release-guards/`（原主工作树的忽略归档，不随 Git 交付）包含：

- `final-edge-red.log`：新增状态校验/字面量美元符保护3项失败；`roles-red.log`：缺角色2项失败；初始RED另见前任务artifacts/2026-09-24/refresh-restore/guards-red.log。
- `guards-green.log`：最终25项专项通过，0.10秒；主目录最终全infra 169项通过，12.28秒，见`infra-main-final.log`。之前166项infra通过12.83秒，角色完整性增加3项后重新验证主目录。
- `images-good-final.log`：两张实际镜像各9组通过。`server-preflight.log`：旧镜像/旧回退拒绝、冻结配置重新渲染与原配置完全一致、24容器不变。
- `server-install.log`：安装及可重复恢复通过，随后验收脚本因错误标记未向外层stderr传播而断言失败。没有把该脚本退出1当作全通过；改用runpy捕获实际CalledProcessError.output验证门禁结果，见`server-acceptance.log`（通过）。未修改门禁来掩盖失败。
- `server-acceptance.log`：真实release rollback拒绝、24容器不变、systemd与状态正常、已安装代码SHA256。`email-test.log`：单封测试邮件SMTP接受。
- `source-sha256.json`：主目录6文件身份；服务器4个运行脚本与对应主目录SHA一致。

仓库/部署策略通过。按[影响与证据复用规则](../runbooks/mobile-delivery-workflow.md)，本次仅运维脚本，未重复执行完整`scripts/verify.ps1`的未受影响API/Flutter/迁移门禁，不宣称全量verify exit0。前次[业务续期修复验证](2026-09-24-refresh-restore.md)的71项API/认证与7组隔离PG证据仍对应未变生产镜像；本次新增最终镜像实测及全部infra测试。

独立reviewer按规格→质量安全完成，发现并修复：实际Compose绑定、管理员入口边界、SMTP文档、修改前完整恢复映射、待发事件丢失、同原因重复发送及缺少角色旁路。最后复审均通过，无上线阻断。

## 配置与恢复

具体变量和操作见[运行手册](../runbooks/refresh-release-guards.md)。安装目录`/opt/starchat/ops/refresh-guards/`；状态`/var/lib/starchat-refresh-watch/state.json`；systemd名`starchat-refresh-watch.timer`。

邮件使用现有worker中的SMTP_*及BUSINESS_WALLET_ALERT_RECIPIENT；凭证不离开worker，不写仓库或日志。最终恢复备份：`/opt/starchat/releases/refresh-release-guards-20260924/install-backup-42f06d813fc145d1a9295b21ec345667`。

现用release入口已强制接入；root直接Docker、其他历史发布脚本仍可绕过，后续发布必须遵循更新后的生产运行手册。门禁不替代数据库/业务完整性验收。SMTP整体不可达或主机宕机仍需独立外部监控；长期SMTP失败期间合并当前状态，不保证保存每次短暂波动。

下一步仅为收件方确认测试邮件和用户复验0.4.6页面；本任务服务端实施无需等待该反馈。
