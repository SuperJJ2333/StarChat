# NETMON 源站 TCP 443 补充探测

本扩展增加两处观察点每分钟对真实源站 IP 的 TCP 443 连接成功率及实测耗时，保留原探针和业务服务。2026-09-26 已安装并取得两个不同分钟的实际定时记录，详见文末；历史结果不替代下一次实时检查。

## 已核对的基线

2026-09-26 从源站与阿里云 Windows ECS 分别解析 `liuhetong888.com`，均为 `207.56.8.8`；源站正在监听 443。因此候选只允许该固定地址，不通过域名探测，不改变 DNS、反向代理、认证、媒体、Matrix 或 TURN。源站迁址时须先重新核对地址并审查脚本 allowlist，不能静默把域名解析结果当作固定源站。

| 现有对象 | 只读检查结果 |
| --- | --- |
| `/opt/starchat/netmon-sg.sh` | 源站至新加坡 TCP 22 探针；SHA256 `4674b11f23fc78972effa2faf2f56d80de54530443c66c65ec91eb11849c6e7a` |
| `/etc/systemd/system/netmon-sg.service` | SHA256 `143f42ed92d79945b813b5157ac26e5774f4492a24b96e0680682efa1b5f46a7` |
| `/etc/systemd/system/netmon-sg.timer` | 每分钟 OnCalendar，active；SHA256 `01c9caa64878c9a765db7c0501cd1afbd911258f5525f43fa4709fe5774a8f2a` |
| `/opt/starchat/netmon-sg.log` | 检查时 10626 字节；旧脚本无显式连接超时、日志为追加写入 |
| 阿里云观察点 | `Administrator@8.163.93.151:22`，Windows，`C:\Python311\python.exe`；检查时没有 netmon/StarChat 命名的定时任务 |

原 netmon 是 TCP 22 回程观察，不能称作 HTTP/TLS 健康检查。上述旧脚本、service、timer 和日志均不由本次安装修改。新的独立 timer 不依赖旧探针完成，避免旧探针连接等待造成 443 样本缺口。既有 HTTP/TLS/业务健康监控也继续保留。

## 采集语义与容量

源码为 [netmon_tcp_probe.py](../../scripts/netmon_tcp_probe.py)，仅使用 Python 标准库。每次定时调用串行进行 3 次连接，单次超时不超过 3 秒；每分钟最多启动一轮，禁止重叠。无请求 payload、TLS 握手、DNS、HTTP、重试请求或用户操作。

- `observer` 只允许 `origin_server`、`mainland_observer`；`target` 固定为 `origin_tcp443`。日志不含实际 IP、URL、用户身份或异常原文。
- `tcp_connect_ms` 从 connect 调用前到其成功返回立即取高精度单调时钟，不含 socket 创建、关闭或 TLS。失败时该字段为 null。
- `attempt_elapsed_ms` 是完整尝试实测耗时；超时也使用实际时钟差，不能把配置的 3000 ms 当作实测值。
- `error` 是 `connect_timeout`、`connection_refused`、`unreachable`、`permission_denied`、`socket_failure` 之一。无异常消息自由字段。
- 每轮 `probe_window` 成功率使用实际 3 次结果。持久 `window` 是最近最多 60 次尝试的成功率；正常每分钟 3 次时约覆盖 20 分钟，漏跑期间不能声称覆盖固定时间窗。空窗口成功率为 null。
- `state.json` 有固定 schema、观察点和最多 60 个布尔值；读取上限 4096 字节。损坏或观察点不匹配时重置窗口并标记 `state_reset=true`，不能沿用未知结果。
- 日志采用 UTC 日期 `tcp-YYYY-MM-DD.jsonl`，最多 7 个文件，每文件最多 2 MiB。上限为约 14 MiB 加小型状态；达到当日上限继续更新状态，返回 `log_capped=true`。只清理自身日期日志，不清理其他文件。
- 目录必须由 root/SYSTEM/Administrators 控制；脚本拒绝直接状态、日志和目录符号链接。Linux 目录 0700、状态和日志 0600；Windows 使用 ACL 限制而非依赖 POSIX mode。

DNS、TLS、TTFB、HTTP 和真实业务延迟均为 **unsupported**。`origin_server` 连接自身公网地址主要验证监听/本机路径；它不能代表国内跨网链路。`mainland_observer` 只代表该 ECS 的网络路径，不能代表所有国内运营商或终端。TCP 成功也不能证明登录、Matrix sync、媒体上传或通话正常。

## 安装清单与预检

使用 [生产工作流](admin-production-workflow.md) 和严格 SSH 主机校验。以下清单只增加独立对象，不改变运行镜像、数据库、Caddy、旧 netmon 或现有告警。安装前重新读取旧三文件 SHA、业务容器 ID/镜像/启动时间，检查新对象不存在；若有未知既存对象，停止覆盖并审查，不使用 force。

| 观察点 | 新对象 |
| --- | --- |
| 源站 | `/opt/starchat/ops/netmon-tcp/netmon_tcp_probe.py`；`/etc/systemd/system/starchat-netmon-tcp.service`；`/etc/systemd/system/starchat-netmon-tcp.timer`；`/var/lib/starchat-netmon-tcp/` |
| 阿里云 | `C:\ProgramData\StarChat\NetmonTcp\netmon_tcp_probe.py`；同目录任务 XML；`state\`；任务 `StarChat-NETMON-TCP443` |

冻结本地候选 SHA256、所有新文件内容及目标路径，服务器备份目录 0700、Windows 备份目录限制为 SYSTEM/Administrators。记录原对象存在/不存在、原权限、原任务 XML/启用状态和候选 hash，不能只备份当前脚本。首次部署预期对象不存在；记录缺省标记。只有已冻结候选可安装，上传后核对 SHA。

### 源站 systemd 模板

先创建 root 独占的代码与状态目录，写入候选脚本和以下两个新 unit；用 `systemd-analyze verify` 校验，再 `daemon-reload`、启用新 timer。原 `netmon-sg.*` 不变。

```ini
# /etc/systemd/system/starchat-netmon-tcp.service
[Unit]
Description=StarChat NETMON origin TCP443 measurement

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/starchat/ops/netmon-tcp/netmon_tcp_probe.py --origin-ip 207.56.8.8 --observer origin_server --state-dir /var/lib/starchat-netmon-tcp
TimeoutStartSec=15
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/starchat-netmon-tcp
RestrictAddressFamilies=AF_INET
UMask=0077
StandardOutput=null
```

```ini
# /etc/systemd/system/starchat-netmon-tcp.timer
[Unit]
Description=StarChat NETMON origin TCP443 every minute

[Timer]
OnCalendar=*-*-* *:*:00
AccuracySec=1s
Persistent=true
Unit=starchat-netmon-tcp.service

[Install]
WantedBy=timers.target
```

同一 oneshot service 运行时 systemd 不重复启动它，15 秒限制小于一分钟。正常失败的连接仍形成结果且脚本 exit 0；监控自身存储/测量失败返回固定错误码并 exit 1，检查 `ExecMainStatus`，不能把探针故障解释为源站网络故障。

### 阿里云 Windows 任务

创建上述私有目录并通过 `icacls` 去除继承，仅保留 SYSTEM 与 Administrators 完全控制；不复制 SSH 密钥、生产配置或 SMTP 凭据。任务 XML 中使用：

- `TaskName`: `StarChat-NETMON-TCP443`，不存在时用 `schtasks /Create /TN ... /XML ...` 创建；不使用 `/F` 覆盖未知任务。
- Principal: `S-1-5-18`（SYSTEM）、`HighestAvailable`。SYSTEM 由 SID 选择服务账户运行；XML 中不写 `<LogonType>ServiceAccount</LogonType>`（任务 XML schema 不接受该值）。先用 Task Scheduler COM 的 `TASK_VALIDATE_ONLY` 校验，不能把失败创建当作任务已安装。
- Trigger: 从下一分钟开始，`Repetition/Interval=PT1M`、无截止期限。
- Settings: `MultipleInstancesPolicy=IgnoreNew`、`ExecutionTimeLimit=PT15S`、`StartWhenAvailable=true`、禁用电池退出限制。
- Command: `C:\Python311\python.exe`。
- Arguments: `C:\ProgramData\StarChat\NetmonTcp\netmon_tcp_probe.py --origin-ip 207.56.8.8 --observer mainland_observer --state-dir C:\ProgramData\StarChat\NetmonTcp\state`。

验收读取实际导出的任务 XML和 LastTaskResult；不能只看创建命令成功。若执行超时或 state 无增长，标记观察点缺数据，不根据旧成功率宣称当前健康。

## 验收与回退

候选已通过 Windows 29 项专项测试，包括成功/拒绝/超时、POSIX 与 Windows WSA 错误分类、真正 connect 计时边界、3 次有界窗口、真实成功率、无伪造失败 TCP 时长、损坏状态、日志容量/保留、任意 payload 拒绝。红/绿证据在 `docs/verification/artifacts/2026-09-26/netmon-tcp/`。

实际同一候选经 stdin 在 Linux/Windows 运行，未安装任务；使用临时私有目录验证状态与日志后清除。源站 3/3 成功，TCP 0.096/0.037/0.039 ms；阿里云 3/3 成功，23.415/13.054/17.969 ms。这些是短窗口实测，不能替代持续成功率。

安装后需看到两台各 **两个不同分钟**的定时执行记录，每分钟恰有 3 个真实尝试；核对成功率分母、nullable 失败字段、日志/状态权限、候选 hash、实际 unit/任务配置。复读原 netmon 三文件 SHA 和旧 timer 状态；业务容器 ID/镜像/启动时间全部保持。不能把手动执行记录当作定时验收。

回退顺序：先核对当前新对象内容仍等于冻结候选；发现后续漂移则停止。然后停止并禁用本次新 timer/任务，按存在/不存在清单恢复原文件、权限和原任务状态；首次安装只移除明确归属本次且 hash 一致的新代码/unit/任务，不删除未知文件。日志保留私有归档，状态目录内其他文件不清理。systemd 重新 daemon-reload 后验证旧 `netmon-sg.timer` 和业务容器不变；Windows 验证本次任务不存在且既有任务不变。回退不涉及 DNS、应用包、服务镜像或数据库。

## 2026-09-26 实际安装验收

运行脚本 SHA256 为 `ec3e2c6b0978b7cad56714c5be85a8258a97e3a7d90a406762053dcf981de531`，两台实读一致。源站新 timer active，service `Result=success`、`ExecMainStatus=0`；目录 0700，状态/日志 0600。阿里云实际任务间隔 PT1M、IgnoreNew、PT15S、SYSTEM，LastTaskResult=0；私有目录保护 ACL，文件仅 SYSTEM/Administrators 可访问。原 142 个任务名保持。

| UTC / 香港时间 | 源站观察点 | 阿里云国内观察点 |
| --- | --- | --- |
| 06:23 / 14:23 | 3/3 成功；0.087、0.046、0.057 ms | 3/3 成功；13.620、11.713、11.021 ms |
| 06:24 / 14:24 | 3/3 成功；0.091、0.044、0.051 ms | 3/3 成功；12.899、18.478、11.729 ms |

记录均来自定时运行，不是手动补样。源站原 netmon 三文件 SHA、旧 timer active 保持；安装前 27 个运行容器的 ID、镜像和启动时间全部保持。这只证明该窗口 TCP 可达，不证明所有业务和客户端路径恢复。

首次 Windows 创建因 XML 的 `LogonType=ServiceAccount` 不受 schema 支持失败；Task Scheduler COM validate-only 返回 HRESULT -2147216616。自动回退移除候选代码，未注册任务；仅在已验证自有 staging 空目录后清理，失败 XML 留私有备份。移除该 XML 元素后 validate-only 通过；SYSTEM SID 实际运行 LogonType=5，第二次创建成功。没有用 force 覆盖既有任务。

私有备份和 hash 拒绝漂移的回退程序：

- 源站：`/opt/starchat/releases/netmon-tcp-20260926/manifest.json`、`rollback.py`。
- 阿里云：`C:\ProgramData\StarChat\NetmonTcpBackup20260926v2\manifest.json`、`rollback.py`。失败候选另在 `NetmonTcpBackup20260926` 保存。

回退执行前核对程序自身 SHA 与同目录 manifest 的 `rollback_code_sha256`；在新对象 hash 仍匹配时执行 `python3 /opt/starchat/releases/netmon-tcp-20260926/rollback.py` 或 `C:\Python311\python.exe C:\ProgramData\StarChat\NetmonTcpBackup20260926v2\rollback.py`。程序以回退当时的新鲜容器/任务清单做前后比较，不使用安装时的历史业务镜像限制后续合法发布。正常安装后的完整撤回未执行；仅首次失败创建的自动撤回已实际执行，不能把保存回退程序说成全流程恢复演练通过。

实际命令、失败记录和脱敏定时证据在 `docs/verification/artifacts/2026-09-26/netmon-tcp/`；专项最终 29 通过。一次使用 `D:/python/python.exe` 的完整 infra 收集被该解释器已安装的同名 `scripts` 包抢占，导致 wallet archive import 错误，不属于并行改动或缺失源码；对应完整门禁以主任务所用正确项目环境的结果为准。
