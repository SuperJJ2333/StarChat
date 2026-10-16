# Android 2217 官方测试入口已更新

2026-10-16T12:59:32.230308+08:00 页面切换；2026-10-16T13:00:34.764393+08:00 最终记录。仅测试入口分发，正式Android0.4.47+2216、iOS0.4.46+2215、最低build3及弹窗设置保持。

- [官方测试入口](https://www.liuhetong888.com/download?platform=android#android-test-candidate)
- [2217 CDN直链](https://d12fjr06o6tga5.cloudfront.net/downloads/ChatFlow-0.4.48-build2217-arm64-candidate.apk)；[官网备用](https://www.liuhetong888.com/downloads/ChatFlow-0.4.48-build2217-arm64-candidate.apk)
- 工件0.4.48+2217 / ARM64 / com.liuhetong.mobile / 73,262,170字节。
- SHA256 `385663ac9d6cfb9befc726151c69883ee540fafd705f5cb9037ec85df1d0d8ac`，固定证书75b31…61fff，与2215/2216一致。
- 页面SHA256 `8932e9e860c1cfcd872553654c4532f65a667ed87cca97867c37488b075cec60`。

## 验收证据

候选入口原1FAIL/2PASS→3PASS；增加重试状态与页面回退后11PASS。现有Node下载专项47PASS/4FAIL，使用原线上页面及同源JS/registry的隔离基线同样47PASS/4FAIL，均为旧正式2213断言，未改写为全绿。完整verify因本地.env缺失未执行；本次不改移动源码，复用已完成的同SHA构建/签名门禁。

独立SPEC→QUALITY通过。上传完整SHA与大小一致，独立inode不可变安装；CloudFront仅新增2217精确路径，18→19个behavior，Deployed，其他配置与桶策略保持。服务器HEAD及工作站6项保留TLS检查通过：候选CDN、官网备用、正式latest HEAD，以及实际download页、正式registry、iOS manifest小文件GET。没有从公网重新下载完整APK。

当次HK前后核对：十项更新设置、正式包哈希、别名、registry、其他静态、schema、永久保护及依赖不变；全部35容器身份/启动时间/restart保持。没有业务服务部署或数据库设置写入。

## 回退与限制

备份 `/opt/starchat/releases/android2217-candidate-download-20261016/download.before.html` 在0700目录内，原页0600。执行证据目录中的 `operate.py rollback-page` 会在共享锁内核对backup和当前after SHA，仅恢复测试入口；若后续页面漂移则拒绝。保留不可变包及CDN精确路由用于取证，不宣称直链被撤销。SG配置快照在 `/home/ec2-user/starchat-android2217-candidate-download-20261016/`。

实际K80保数据升级与小米告警消失仍待用户验证。此前修复的是原生Getui同意门禁，不能推断安装标签已消除；旧登录同意迁移和SDK运行时缺口仍在[修复报告](2026-10-16-android-antivirus-review.md)。

工作树download.html与线上逐字节一致。primary原先只有4处历史正式版本元数据滞后，核实无其他差异后备份并回填当前精确页面；未进行整个primary站点部署。证据目录：[android2217-candidate-download](C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/docs/verification/artifacts/2026-10-16/android2217-candidate-download)。
