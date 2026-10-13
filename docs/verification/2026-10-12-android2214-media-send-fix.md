# Android2214图片/视频发送P0修复

## 结论与根因

用户报告0.4.45（2214）图片、视频普遍发送失败。已在实际main debug2214复现：相册JPEG出现红叹号，MP4提示暂无法发送。启动时`_bindConnectionStatus()`间接开始绑定媒体outbox，捕获旧generation；await secure binding后`_startup.open()`已推进代际，安全检查拒绝绑定，图片/视频共同触发`owner-unavailable`。

最小修复：先open启动代际并标记matrixReady，再绑定连接状态/媒体队列。保留账号、代际、取消、撤销、E2EE、权限和重试保护；没有绕开鉴权或隐藏错误。正式候选0.4.46（2215）。

## 实际验收

| 项目 | 结果与范围 |
|---|---|
| 未修复复现 | 5556，Android9/API28 x64，main debug2214；JPEG红叹号、MP4失败、queue inactive |
| 修复debug | 固定75b31签名/常规重建，保数据覆盖2212→2214→2215，UID10090保持 |
| 图片 | 实际相册UI选择合成JPEG，m.image/synced/服务端ID=true，无红叹号；13K原图可打开 |
| 视频 | 实际相册UI选择3秒H264，完成上传、可播放，画面/进度0→2秒；跨进程重开PID10821→11824仍m.video/synced/服务端ID=true |
| 目的地与隐私 | 真实当前App/SDK/账号，仅一名成员的加密房间、零邀请；无其他收件人，无token/key/正文导出 |
| 回归 | 固定依赖RED→GREEN14、邻接7、独审14；最终Flutter5965PASS/9SKIP/0FAIL，analyze无问题，Python401PASS/1SKIP |
| 正式包 | ARM64 nondebug/min24/target36，28步骤exit0、fixed75b31/v2/v3、25414class/168863methods/274lib+assets source-final相等 |
| 原生边界 | 400source/57smali/fullmanifest严格闭包；14库source-final相同，13旧库字节相同，仅libapp变化；13required/alternative crypto exports已核 |

Debug包125901146B，SHA `e3bd89359c3822e54dc6c6daa28d12c0117ff6f25f7c7a968eb03416d507ac2a`。正式包73262170B，SHA `4b43bd1ca655918b9754183c1713ed5eb6e864379a2e2ccc6bd861195578b6a6`。

[真实模拟器证据](artifacts/2026-10-12/android2214-media-regression/README.md)、[最终共享门禁](artifacts/2026-10-12/media-2215-final-gates/README.md)、[任务记录](../workflow/tasks/2026-10-12-android2214-media-send-regression.md)。服务器只读窗口六次upload200不能归属本次旧2214，不据此断言所有上传正常。

## 交付与限制

模拟器debug已安装。正式ARM64 0.4.46（2215）于2026-10-12 22:25（+08）发布成功，22:28平台路由与三条审计读回通过，22:31工作站8次请求/11项断言通过。官网/CDN HEAD 200且73262170字节一致；Android更新配置2215，iOS仍2213、两端最低build均3。发布过程未重启服务。仅两个下载源文件已按精确SHA回填，其他五个保护文件保持。

[下载2215](https://www.liuhetong888.com/downloads/ChatFlow-0.4.46-build2215-arm64.apk)。[公网检查](artifacts/2026-10-12/android2215-public-workstation-check/README.md)。冻结包r2为`d08e5c8aa80af4429c6dd8d8a953279d907ceb4c4b281f684998036d1a9a558b`，旧b93b包完整留档但未执行。

这是一台API28 x64模拟器、本人加密房间的真实媒体路径验收，不代表所有ROM/真机、独立第二接收端、弱网/大媒体压力。现有libcrypto4KiB/16KiB静态exit1及RELRO尾页风险原样保留，zipalign-P16不等于ELF16KiB运行通过。全仓verify真实exit1缺本地.env，未复制生产秘密；适用客户端门禁通过。附加独立smali长路径重放180秒超时单列未完成，原builder成功退出及实际输入/report身份已审，不假称附加重放通过。

## 时间与环境返工

任务开始2026-10-12T19:17:40+08；debug正式构建/重建12:38:03–12:45:29Z，安装12:52:29Z；最终Flutter全量7分40秒；正式ARM64构建88.8秒、重建总结束13:25:17Z。其余主动执行/环境恢复/评审总耗时未单独精确计量，保留真实命令退出码。旧工具路径失效、DPAPI密文末尾换行、最初未固定pub host的构建及VM编译服务/URI轮转问题均留诊断，弃用依赖漂移的中间包；不把这些失败当产品通过证据。
