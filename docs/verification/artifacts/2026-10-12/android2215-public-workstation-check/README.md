# Android2215 工作站公网轻量后验

`WORKSTATION_PUBLIC_LIGHTWEIGHT_PASS`。root 明确 GO 后，在 `2026-10-12T14:31:21.252944Z` 至 `14:31:22.851633Z` 通过自建 jumper SOCKS 发出 8 个只读请求；检查器 exit 0，无自动重试。实际 curl 8.13.0/Schannel，HTTPS-only、保留证书校验，全部 ssl_verify_result=0、effective URL 精确一致、不跟随重定向。GET 最大 256KiB，每请求总预算 25 秒；未传用户凭据。

| 检查 | 实际结果 |
|---|---|
| 官网不可变2215 APK HEAD | 200，73262170 B，APK MIME，body下载0 |
| CDN同名APK HEAD | 200，73262170 B，APK MIME，body下载0；CORS精确 `https://www.liuhetong888.com` |
| Android registry小JSON | 200，application/json + no-store；0.4.46/2215、两URL、73262170 B和SHA256 `4b43bd1ca655918b9754183c1713ed5eb6e864379a2e2ccc6bd861195578b6a6` 全匹配 |
| 官网下载页 | 200，新Android0.4.46/2215与原iOS0.4.44/2213文案存在 |
| iOS plist | 200，bundle `com.liuhetong.liuhetongMobile`/2213及原0.4.44-2213-9e5d3582 IPA URL保持 |
| Android/iOS/legacy update route | 三个无鉴权GET均401 |

官网同源APK HEAD 未返回 Access-Control-Allow-Origin；既有发布契约只对跨域 CDN 要求 CORS，本次 CDN 检查通过，没有将官网缺该头写成“双方CORS通过”。

`public-receipt.json` SHA256：`a77be6c68b0196a4bcda70390fdc3891c8a6a21b0da6a49ed44d26827510bb10`。HEAD仅证明访问/长度，registry SHA是实际公告的值，不是本次重新下载APK计算的hash或验签。新包完整性/签名来自root正式构建与上传证据，本代理没有回拉安装包。

## 实际设置的独立证据层

公网401不会暴露版本/最低版本。`root-publish-audit-binding.json` 只读绑定root已成功执行的publish与实际route/audit文件原始SHA：publish `410be3f5df4e7021567c3f639cebbac2b34ba810bd5f8270c01b1dc3f31f6d63`；audit `57a0fadab5ccd96416ccfdaf480e91305cf200268f841e21dfeb552aa0079a92`。实际投影 Android0.4.46+2215/min3、iOS0.4.44+2213/min3/configured=true；恰好3个审计键 app_latest_build/app_latest_version/app_update_notes。这是root服务端只读结果，本代理没有再次访问DB或把公网401冒称设置验证。

## 隧道与本地诊断

Start-Process使用Hidden、仅127.0.0.1:23342，StrictHostKeyChecking/ExitOnForwardFailure开启。自建PID241020、原始启动时间14:20:20.4688412Z；检查后14:31:22.9258054Z已关闭。关闭前比较PID对应的可执行路径与UTC ticks，仅清理此进程；见tunnel-start.json和tunnel-stop.json。

首次执行在HTTP前因PowerShell ConvertFrom-Json 自动把时间解析为 DateTime，旧字符串比较误拒绝；没有公网请求或进程终止发生。只修为精确UTC ticks比较，保留路径比较。tunnel-owner-format-red-green.json用原receipt做本地无进程动作回归：旧比较复现假拒绝，精确ticks通过，差1 tick拒绝。之后8个HTTP请求只执行一轮，无重跑已完成旧测试。

仅新增本独立目录。未上传、变云、生产写、重启、业务重放或完整APK/IPA下载；没有用户正文、附件、令牌或钱包数据。root负责总任务和发布结论，工作站轻量结果不替代ARM64真机覆盖/安装验收。
