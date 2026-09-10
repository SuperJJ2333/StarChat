# ADR 0067：生产时钟渐进校正与人工修复时间守卫

状态：2026-09-10 已通过领域及质量/安全评审；首次运行暴露的采样间隔问题已修正，频率恢复方案再次通过两项评审。范围：用户已授权的异常根因修复，不授权充值、提现或事故自动结案。

2026-09-10 两个独立 TLS 验证的 HTTP Date 源显示主机快约60秒；九个NTP端点超时，本机规则允许出站UDP，具体网络阻断点尚未证实。不可把当前偏差推定为历史每笔订单的偏差，也不可修改订单原始时间。

采用固定 Ubuntu 软件包 chrony 4.5-1ubuntu4.2 的解包二进制，隔离在 root 拥有的 `/opt/starchat/releases/clock-20260910`。校验软件源下载、包版本、依赖与文件散列。避免安装软件包移除现有 timesyncd。保存原服务启用/运行状态和配置；在启动自定义服务前停止 timesyncd，始终只保留一个时间纪律进程。

自定义 chronyd 配置启用 manual、maxdrift 500、maxslewrate 100000、独立pid/socket/drift路径、port 0、cmdport 0。maxdrift 限制长期频率修正，maxslewrate 独立限制消除当前偏差的临时速率。不存在 makestep、initstepslew、自动上游或启动 -q。时钟通过降低运行速率渐进追平，不直接回拨。约60秒偏差在最大速率下约10分钟，但必须实测收敛，不能根据估算宣告完成。短期TTL的墙钟速率会变化，发布与验证阶段禁止并行生产切换。

独立timer每5分钟运行 `scripts/starchat_clock_feed.py`，取Cloudflare及TronGrid两份新鲜Date，完整TLS验证、禁止重定向、不接受Age缓存、RTT不超过2秒、两源偏差不超过2秒、绝对校正不超过120秒。失败不校正并通过systemd失败状态与日志暴露，不复用旧样本。人工输入为 chronyc settime 支持的手动时间源，不执行step命令。

首次启动时，已经过去的 `OnBootSec=30s` 在首次主动feed后约1秒再次触发；两份整数秒手动时间样本间隔过近，频率估计出现约128764 ppm fast。该问题不能用 `manual reset` 或仅删除第二份样本修复：reset 保持当前纪律参数不变，删除后只剩一份样本时也不会恢复原绝对频率。先停止timer，保持金融健康守卫，再通过 `scripts/starchat_clock_release.py recover-frequency` 恢复：停chronyd后保存其最终drift文件，写入 `0.0 100000.0`（中性频率及宽误差界），采用新的500 ppm频率上限重启并输入一份新鲜样本。不能只删drift文件，否则可能继承内核中的错误频率；不能在停止前保存后直接假定文件没有被退出流程重写。

当前timer改用 `OnActiveSec=300s` 和 `OnUnitInactiveSec=300s`。feed将成功提交的boot ID及monotonic时刻原子保存到 `/var/lib/starchat-clock/feed.json`，同一次开机内间隔不足300秒时只观察、不再次提交；重启后不把旧boot的monotonic值与新boot混用。该规则依赖systemd同一个oneshot服务不并行执行，不授权绕过服务并发运行多个apply进程。若恢复时已有不足300秒的成功记录，首次feed可以跳过，应以实际日志确认下一次接受时间。

新金融例外命令以 ClockHealth 独立测量主机偏差，保守计入Date秒精度与RTT误差后不超过5秒才健康。默认探测运行于可终止子进程，6秒超时即失败关闭；缓存最多15秒，墙钟跳变使缓存立即失效；API保留最终授权、资金核验和链证据检查。健康检查不等价于链最终性或精确UTC证明。

回滚：先停并禁用新timer，再停chronyd，恢复原timesyncd开机启用设置，但保持停止，需另行确认安全对时策略后才能启动（防止NTP恢复时发生step）；不恢复错误墙钟。保留审计与发布目录。若原NTP仍不可达，资金例外继续因ClockHealth失败而阻断。常规发布独立修复开关默认false，可单独关闭。

验证：独立源失败/不一致/偏差超界/缓存跳变拒绝；受控样本对chronyc的命令严格限定；上线连续测量偏差收敛、墙钟不回跳、原业务健康、无自动资金写入。

实测证据：最初四次TLS校验请求测得主机快59.428—60.052秒，RTT为0.279—0.493秒。恢复后服务日志在2026-09-10 13:39:12、13:44:13 UTC分别记录offset_seconds=-0.553、-0.570，healthy=true；后一轮两源RTT为0.280、0.421秒。相应tracking频率限制在500.000 ppm，更新间隔300.9秒。该手动源模式下 `Leap status: Not synchronised` 仍可出现；它不表示已恢复NTP，也不能单独代替HTTPS独立健康测量。HTTP Date有秒级量化和未知上游时钟误差，当前结果证明这些采样时刻满足保守5秒守卫，不证明永久精确UTC或任何历史订单时间正确。

证据位置：工作区 `docs/verification/artifacts/2026-09-10/admin-clock/`；服务器 `/opt/starchat/releases/clock-20260910/frequency-recovery.json`、受限的pre-recovery-drift及systemd日志。主流程见 [admin-completion-deployment.md](../runbooks/admin-completion-deployment.md)。官方机制依据：[chronyc手动样本语义](https://chrony-project.org/doc/4.5/chronyc.html)、[maxdrift与maxslewrate](https://chrony-project.org/doc/4.5/chrony.conf.html)、[4.5频率上限实现](https://raw.githubusercontent.com/mlichvar/chrony/4.5/local.c)。
