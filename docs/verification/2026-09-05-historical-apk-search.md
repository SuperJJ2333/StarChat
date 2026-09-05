# ChatFlow 0.3.1 历史 APK 查找

2026-09-05，通过 root@207.56.8.8:23421 执行只读查询。默认 SSH ProxyCommand 引用不可用的 connect 程序；仅本次命令使用 ProxyCommand=none / ProxyJump=none 成功直连，未修改 SSH 配置。

结果：未找到 ChatFlow 0.3.1 原始 APK，未改动服务器部署。

- `/opt/starchat/frontend/downloads` 仅保留 0.3.36 三架构 APK 和 latest 符号链接。
- 对根文件系统执行 APK/0.3.1 名称搜索（排除 Docker 内部目录）；另检查 /opt、/srv、/var/www、/root、/tmp。只发现当前包和下列旧包。
- `/opt/starchat/releases/mobile/starchat-ef7e515-release.apk`：137692120 bytes，8 月 25 日文件；现有 2026-08-25 验证记录亦对应此文件。
- `/opt/starchat/releases/mobile/liuhetong-a00efbb-public-debug.apk`、`liuhetong-481965a-public-debug.apk`：各 229964727 bytes，8 月 26 日文件。未读取这三份旧 APK 的包内版本，不能把它们当作 0.3.1。
- 检查 `/opt/starchat-backups` 两份 tar.gz、`/opt/starchat-migration/starchat-source.tar.gz` 及 `/opt/starchat/backups` 两份 tar.gz 的成员名，未发现 APK 或 ChatFlow-0.3.1 项。
- 本地仓库含忽略目录的文件名搜索也未发现 `*0.3.1*.apk`。
- 历史记录 `docs/verification/2026-08-30-add-friend-search.md` 确认 0.3.1 曾发布，build 4，arm64 哈希仅记有前缀 31B0ABBA；旧 URL 为 https://www.liuhetong888.com/downloads/ChatFlow-0.3.1-arm64.apk。
- `docs/verification/2026-08-30-emoji-gallery-image-picker.md` 明确记载发布 0.3.2 时“0.3.1 包下线”。下线记录与本次未找到文件相符，但不能证明所有外部备份均不存在。

未检查云厂商快照、外部备份、其他设备下载缓存或 GitHub 历史构建资产。需要这些来源才能继续寻找原始包。重新构建旧代码不能当作原始报毒 APK。
