# 广州节点公开 HTTPS 试点运行手册

本试点在用户提供的广州 Windows ECS 上、现有 Employ26 Caddy 2.11.4 配置后，仅追加 `edge-cn-probe.liuhetong888.com`。它只转发 Business ready 和 Matrix versions 两条公开 GET；任何登录、短信、Matrix 同步、媒体或通话请求均未接入，不能用试点健康状态宣称这些业务恢复。

## 固定边界

- 主域名 `liuhetong888.com` 的 A 记录继续指向源站；测试子域名 A 指向广州节点，TTL 600 秒。不要把两者放进同一个多 A 池。
- 原 Caddyfile、已有站点、服务、证书和访问控制保留。试点部署脚本仅在原配置文件与运行配置哈希同时符合已冻结基线时执行；先复制原文件和 ACL，再 validate、reload。回退也只接受该基线加上精确试点块的状态，并核对恢复后的**运行配置**。激活时原脚本与现行修正脚本的哈希、回退测试见[验证报告](../verification/2026-09-25-domestic-edge-network.md)。
- 上游固定为源站地址，证书按主域名 SNI 验证，HTTP Host 使用主域名；阻止 DNS 切换后的代理回环。公开试点删除上行 Authorization 和 Cookie，其余路由直接 404。
- 该主机上原 Employ26 IP HTTP 访问为 308。IP HTTPS 握手在试点前后均失败，不在本试点验收范围；不得声称 HTTPS 已恢复。

## 发布与回退

使用仓库 [受约束的部署脚本](../../scripts/edge/starchat_public_probe.py)。在 PowerShell 7 中先设置 UTF-8 无 BOM 和 Python UTF-8 环境；SSH 使用已核验的 Windows 主机密钥、`BatchMode=yes` 和严格主机密钥检查。远端 Python 为 `C:\Python311\python.exe`。标准输入传脚本，远端不保存脚本副本；不要输出原 Caddyfile，因为已有站点可能含认证配置。

```powershell
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$script = Get-Content -LiteralPath scripts/edge/starchat_public_probe.py -Raw -Encoding UTF8
$script | ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -p 22 Administrator@8.163.93.151 'C:\Python311\python.exe - prepare'
$script | ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -p 22 Administrator@8.163.93.151 'C:\Python311\python.exe - activate'
```

`prepare` 已在 2026-09-25 完成；目前运行态已启用试点。再次运行 `activate` 会因已启用而拒绝，不能作为健康检查。发布验收应在 MI 6 上严格 TLS、禁用代理访问两条公开 GET，各获 200；POST/auth/admin 获 404，原 IP HTTP 308 保持，工作站检查测试域名证书 SAN。完整历史证据见[验证报告](../verification/2026-09-25-domestic-edge-network.md)。

如试点造成问题，先确认当前配置确为冻结原文件加上精确试点块，再执行：

```powershell
$script | ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -p 22 Administrator@8.163.93.151 'C:\Python311\python.exe - rollback'
```

脚本从 ACL 保留备份还原、validate、reload 并核对原 SHA。主域名未切流，回退无需变更客户端、源站、TURN 或生产数据库；之后可删除测试子域名 A 记录。若配置已由其他任务修改，脚本会拒绝覆盖，需要按当前运行配置重新审查，而不是强行回滚。

## 扩展门禁

完整国内入口需要分别解决：TURN 独立域名/证书/旧 URI 过渡、广州和源站 HTTPS 证书持续续期、广州 Caddy → 源站 Caddy → Docker Nginx → Uvicorn 的真实客户端 IP 信任链、认证限流、Matrix/E2EE 与媒体、`/ios-call/`、2 GiB 共享节点容量和原业务回退。先完成[分阶段计划](../superpowers/plans/2026-09-25-domestic-edge-network.md)中的测试和安全复核，再决定主域名 DNS 切流。
