# 正式源码合入与好友状态修复

用户范围：把相册及此前会话修复合入正式构建，保留已发布钱包；删除好友成功后立即刷新；修复新好友私聊不能收发。

## 变更与验收

- 将聊天分支 `4afbc6c→9f3cef8` 的会话/相册补丁按文件合入 D 盘正式目录。最近图片每次查询使用新的日期上限，打开面板、回前台及媒体变化时刷新；此前消息、媒体缓存、群管理和公告修复一起保留。
- 删除 API 成功后，先移除共享 ProfileRepository 联系人和 Matrix 映射、通知界面及持久化，再退出资料页。取消或删除失败不改好友状态。聊天页同时清除旧好友资料入口。
- 本地成功删除/更新优先于更早发出的 preload、refresh、quiet refresh 和磁盘 hydrate；后续新请求仍能识别重新添加。失败的 preload 可以重试。
- 新好友私聊邀请不再在加入前调用无权限的 `/members`。同步及共享联系人更新时，处理来自当前业务好友的加密双人邀请；陌生人、非加密房间及已知额外成员不自动加入，与自动加入群聊设置独立。
- 慢邀请按房间隔离、等待设超时。规范房间不存在于本地时按真实 ID 加入；加入已同步则不重复等下一次房间事件。`m.direct` 是账户数据，其修复不再等待房间消息。
- 两个“发消息”入口共享联系人仓库。已有缓存好友无需额外联系人请求；新好友资料缺失时先从业务 API 核实，避免空缓存导致不可发送，也不凭旧资料页面自行恢复已删除好友。
- 实际 RoomPage 卸载测试发现语音浮层清理仍可能 setState，增加最小退场保护。

## 验证

回归先 RED 后 GREEN：实际资料删除导航；旧网络/磁盘结果恢复好友；失败预加载重试；邀请前取成员 `M_FORBIDDEN`；慢邀请阻塞；已加入仍重复等待；真实通讯录消息回调使用旧共享缓存；真实房间删除后旧资料入口；规范房间同步及账户元数据等待。日志位于同名 artifacts 目录。

- 最终 Flutter 全量 **1282 项通过**，`flutter analyze --no-pub` 无问题。
- 钱包专项 **7 项通过**。本次未改钱包业务源文件，也未部署后端或迁移。
- `scripts/verify.ps1` 通过：Business API/Worker 956 passed、31 skipped，Flutter 边界、UI 契约、OpenAPI、离线迁移、Compose 等通过。跳过项保留测试环境条件；日志保留既有 Pydantic/Starlette 依赖弃用提示，不称零警告。校验期间其它钱包任务继续修改后端迁移文件，此处结果对应本次运行时快照。
- 独立规格审查后进行质量审查；两项 P2（旧好友入口、规范房间无限等待）补回归修复后复审通过。
- 未向真实好友发送测试消息或删除真实好友；未完成双设备端到端收发或本次真机覆盖安装，不以单元测试代替用户实测。

## 构建来源与签名

从 `D:/pythonProject/outsource/StarChat` 构建 standard/release/ARM64，显式版本 `0.3.51 / 53`，三个 HTTPS 构建地址均为 `https://liuhetong888.com`。构建前后核对 270 个 Dart/依赖源码文件哈希一致。

保留该目录原有钱包及 iOS 工作，重叠 app_home 只做消息入口修改，Figma/组件登记按键合并。提交仅收录本次拥有的改动，既有未提交钱包/iOS 工作仍留在工作区；APK 包含已发布钱包源码，准确构建来源见 `source-manifest.json`，不能把单一提交号当作完整工作区快照。此前 UI 补丁的远程 Figma 同步限制仍按其原验收报告记录。

按固定流程 Apktool 2.12.1 完整重建，build-tools 36.0.0 对齐和固定签名：

- 包名 `com.liuhetong.mobile`，versionCode **53**，versionName **0.3.51**；ARM64，无 debug kernel/debuggable。
- 正式证书 SHA256：`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，与线上 0.3.50 相同。未使用 Mi 6 debug 签名。
- 大小 **75,994,052 字节**；SHA256 **ba575b7bb4a1f9808e178a167d63b2cccbc9eb9ac1048f2a2729adf3d0ca49fc**。
- 重建前后 **24,573 个类**语义一致，**331 项原生库/资产**哈希一致，清单语义一致。

## 发布

已于 **2026-09-07 20:49:42 香港时间**发布 `0.3.51 / build 53`。不可变文件为 `https://www.liuhetong888.com/downloads/ChatFlow-0.3.51-arm64.apk`。本地、服务器文件、公网版本下载及 latest 完整 SHA256 一致。

经 SettingService 在同一事务更新五项设置，产生 **5 条 settings.update 审计**，trace 为 `release-0.3.51-build53`；最低支持 build 保持 **3**。原子切换 latest 后再次下载校验通过。保留旧 APK；旧设置及符号链接目标备份位于服务器 `/opt/starchat/releases/friend-release-0.3.51/publication-backup.json`，支持条件回退。发布前资金关闭预检通过，未改变钱包开放状态。

首次分块上传有一个 SSH 连接中断；按远端分块 SHA256 复用已成功的七块、补传剩余块，合并全包哈希通过才发布。未跳过校验或使用未完成上传的文件。

证据目录：`artifacts/2026-09-07/friend-release-integration/`。APK、日志、源码差异备份、发布脚本及快照不纳入 Git。
