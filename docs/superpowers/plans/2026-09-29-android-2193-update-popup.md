# Android 2193 更新弹窗文案发布计划

## 目标与授权

用户已明确要求发布 Android 新版本更新弹窗。正式包 `0.4.24+2193`、下载页及更新版本设置已发布；本增量只把 `app_update_notes` 改为「修复 USDT 提现报价显示异常；优化聊天搜索、朋友圈视频与部分页面体验。」。现有自动弹窗与“关于畅聊”共用平台设置，不重新发布 APK、静态文件或服务。

## 文件与边界

- 新增一次性发布器 `scripts/publish_android_update_popup_notes.py` 和专项测试 `tests/mobile/test_android_update_popup_notes.py`。不修改既有发布器、业务 API、移动源码或现有设置键定义。
- 输入按 SHA256 锁定已发布 `release-network.json` 原件及 HK 2193 `network` 阶段私有 `after.json` 十键快照。执行前即时重读全部十键、确认审计 trace 在**全部审计类型中**都不存在；只有 Android notes 有差异时才执行一次 `SettingService.set_many`。
- 锁定服务器本地最终 APK 的大小及 SHA256、下载页、Android registry、三段下载 JS 的字节 SHA256；公网只请求 HEAD APK 和有界的小型静态文件，禁止完整下载 APK。
- 与 `release_metadata.py` 共用主机锁。预检不写设置；执行前在宿主机全新私有 `0700` 目录保存完整十键及空审计前态。数据库结果不明时保留快照与审计供人工核查，不盲重试或无审计回滚。
- 生产通用 `release_settings.py` 仅允许 Android 版本、构建号和 URL，不能写 notes；本次一次性脚本内嵌**仅允许** `app_update_notes` 的 PostgreSQL 事务，沿用发布事务的 advisory lock、十键 `FOR UPDATE` 顺序和 savepoint 绑定 `SettingService`。在同一事务内核对十键、经服务写入并回读，失败时设置与审计一起回滚。外部命令若在数据库提交后失去响应，仍必须按 trace 和现值核查，不能假定失败或再次执行。
- 写后逐键核对十键（另九键完全不变），并核对精确一条 `app_setting`、`ADMIN_SETTING_UPDATED` 审计。前检发现身份、包、静态、设置或审计漂移即拒绝写入；数据库事务内再次检查设置漂移，未匹配则不提交本次写入。

## 测试和发布步骤

1. 先编写测试，运行专项测试观察目标行为缺失导致 RED；再写最小发布器，运行专项测试转 GREEN。
2. 运行相邻 `release_metadata`/iOS 弹窗测试及适用的移动端发布测试；对照本计划做规格审查，再做质量和安全审查。
3. 生产只读预检：复核 API/设置十键、备份来源、HK APK 和静态 SHA、公网 HEAD 与静态、iOS 2189。漂移则停下并调查。
4. 把经过审查的脚本上传至 HK 私有 2193 发布目录，执行一次写入，复核私有备份、单条审计、两端设置及公网更新路由。不得写或删除其它设置、包、页面与审计。

## 完成条件

Android 2193 自动更新弹窗及“关于畅聊”均由同一 `app_update_notes` 显示新文案；版本、build、下载 URL、最低支持 build 和全部 iOS 设置保持执行前值。真机是否实际弹出仍需可用旧版正式包和真实登录设备验证；服务器设置读回不替代真机验收。
