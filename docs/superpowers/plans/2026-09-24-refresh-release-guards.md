# 续期防复发门禁执行计划

用户批准的三项措施与设计见../specs/2026-09-24-refresh-release-guards-design.md。root独占设计声明文件，在.worktrees/refresh-restore执行。

1. 测试先行：旧镜像/任一目标不通过禁止全部切换、只允许镜像digest、探针失败和阈值/去重/恢复/通知失败边界；确认RED。
2. 写实际镜像ASGI协议探针与统一切换guard，接入现用release.py的deploy/rollback。旧不兼容镜像实测拒绝，现用新镜像实测通过，不实际回退。
3. 写有界日志统计和协议探针watchdog，systemd service/timer与服务器本地状态。按用户补充指示复用worker报警邮件，凭证只在worker读取。对失败/恢复/发送失败测试，发送一封明确标记的通道验证邮件。
4. 焦点测试与infra/部署策略，复用未变API/Flutter证据；先规格后安全审查。安装运维脚本与timer，不重启业务容器，核对镜像/容器不变。回退仅撤除本任务timer/guard接入，不修改已恢复续期代码。
5. 文档回填主目录本任务文件，证据哈希一致；准确区分SMTP接受与收件箱确认，说明主机root直接docker不在门禁强制边界内。
