# 正式钱包更新候选 0.3.50

用户已明确授权面向正式用户推送，沿用线上正式版签名。**已于 2026-09-07 14:54:43（香港时间）发布 0.3.50 / build 52 更新配置，latest 已切换至新包。** 用户确认两笔链上记录及各自详情正常显示后执行发布。

## 构建和签名

- 当前源码构建：standard / release / android-arm64，版本通过参数指定为 0.3.50 / 52；不修改既有工作区源码版本。保留 Business API、Matrix、Getui 三项正式 HTTPS 参数。
- 线上上版：0.3.46 / 49，最低支持 build 3。服务器下载的上版 APK 经 apksigner 验证，证书 SHA256 为 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。
- 最终新包证书与上版一致；v2/v3 验证通过。只使用既存受保护发行密钥，未创建、上传或打印私钥/密码。MI 6 debug 签名不用于正式发行。
- Apktool 2.12.1 重建 DEX/资源/清单，build-tools 36.0.0 做 16K 对齐和签名后检查。24,573 个类语义一致，331 项原生库与资产哈希一致，完整清单语义一致。
- 包名 `com.liuhetong.mobile`，仅 arm64-v8a，无 debuggable/debug kernel。最终大小 75,928,516 字节。
- 最终 SHA256：`dd68842e4a1630f595b39daa7875ece20246637fa7f57d0f65d60d36211da87e`。
- 钱包 Flutter 专项 7 项通过；应用更新及版本配置测试通过。构建退出 0，既有 Kotlin 插件迁移提示仍保留。

## 下载和发布状态

候选文件：`https://www.liuhetong888.com/downloads/ChatFlow-0.3.50-arm64.apk`。本地最终包、服务器文件、公网完整响应 SHA256 一致。上传采用新的不可变文件名，未覆盖旧包或更新 latest 符号链接。

五项更新设置已通过 SettingService 在同一事务中更新，记录 5 条 settings.update 审计，trace 为 `release-0.3.50-build52`。最低支持 build 保持 3，未新增强制升级要求。更新文案明确真实绑定、充值入账、提现和兑换仍未开放。回读版本、构建号、最低支持版本和不可变 APK URL 均一致，latest 公网完整响应哈希与最终包一致。

发布脚本在 PostgreSQL 同一事务锁内核对完整旧设置，再调用应用设置服务；不生成用户令牌或冒充管理员。旧设置及下载目标备份位于服务器 `/opt/starchat/releases/official-wallet-0.3.50/publication-backup.json`。脚本支持仅在设置仍匹配此次发布时回退；旧 APK 保留。

## 后台验收边界

生产 API/Worker/观察器在发布后健康复查通过；单源对账 SOURCE_MATCHED、2 笔观察事件可读取，资金关闭预检通过。浏览器连接不稳定，自动逐笔 UI 验收未完成；用户随后明确确认两笔记录及各自详情正常，并提供了字段内容。生产页面验收依据为用户实测反馈，不冒称自动化验收。记录保留“平台入账尚未核定、用户归属尚未核定”，符合只读监控边界。真实地址和完整交易标识未复制到仓库。

本机 ADB 未连接任何设备，本次未进行真机安装，不宣称已验证覆盖安装。

证据目录：`artifacts/2026-09-07/official-wallet-update/`，包含构建日志、测试日志（钱包 7 项、更新与版本配置 19 项）、上版签名、`package/verification.json`、`download-verification.json`、`published.json`、`published-settings.json` 和前次更新设置。下载准备阶段报告中的未发布状态是历史状态，最终状态以 published.json 为准。
