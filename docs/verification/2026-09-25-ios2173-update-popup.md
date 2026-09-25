# iOS 0.4.7/2173 应用内更新弹窗发布验证

时间：2026-09-25 09:44–09:48 +08。用户在官网 2173 分发后反馈可用并要求启用更新弹窗。本次只更新 iOS 应用内检查设置，沿用既有官网下载页；最低支持 build `3`，为非强制更新。

## 输入身份与测试

- 已发布最终 IPA：`ChatFlow-0.4.7-build2173.ipa`，61,495,036 字节，SHA256 `29d9946b3469d59c64d73d679838623873930f8a7c2ae7c087eb2e5589acc3d0`。这是之前用户明确接受企业签名服务注入后、按精确 SHA 发布的同一个包，未重新构建或改包。
- 发布器 [publish_ios_update_popup.py](../../scripts/publish_ios_update_popup.py) SHA256 `8dd5c8fbfc29c4f66ddcfbd3def30d2727a254f235411707c08e558af3799265`，服务器上传后哈希一致，`python3 -m py_compile` 通过。既有 `release.json` 与静态发布 `result.json` 的精确预检通过。
- 测试先验证模块缺失的预期失败，再完成成功路径和官网静态/十键设置漂移拒绝测试。`py -3.12 -m pytest tests/mobile/test_ios_update_popup_release.py tests/mobile/test_ios_static_link_release.py tests/mobile/test_release_metadata.py -q --tb=short`：**97 passed**；平台隔离相关后端测试另有 **23 passed**。独立规格/质量审查无发布阻断。

## 发布及回读

- 服务器发布记录：`/opt/starchat/docs/verification/artifacts/2026-09-25/ios2173-link-only-release/release.json`；静态发布结果：同目录 `backup-20260925T0842HKT/result.json`。弹窗发布私有备份：`/opt/starchat/docs/verification/artifacts/2026-09-25/ios2173-popup-20260925T0944HKT/`，内含 `before.json`、`result.json`、记录与静态结果；审计 trace 为 `ios-popup-0.4.7-2173-20260925T0944HKT`。
- 发布命令返回 `IOS_UPDATE_POPUP_PUBLISH_PASS`，`latest_version=0.4.7`、`latest_build=2173`、`audit_count=3`。三条审计均为 `settings.update` / `SUCCESS` / `ADMIN_SETTING_UPDATED`，准确覆盖 iOS version/build/notes。更新说明：`优化 iOS 登录与本地聊天身份恢复；完善群公告、朋友圈、个人中心及钱包体验。`
- 独立回读十项设置：iOS `0.4.7/2173`、`app_ios_min_supported_build=3`、URL `https://www.liuhetong888.com/download?platform=ios&install=1`；Android `0.4.7/2172` 及其最低构建号、APK URL、说明未变。服务器最终 IPA 和三个官网文件 SHA 与上次网站发布一致。`release_metadata.py check` 返回 `METADATA_CHECK_PASS (no binary download)`；公网 ready HEAD 成功。
- 第一次发布后独立 `docker exec` 回读进程退出 137，API 容器当时重建。随后容器为 `running,false,0` 且 healthy；十键回读、公网 ready 和官网检查成功。上述瞬断不算成功回读，结果以重做的检查为准。

## 范围与后续

旧 iOS 客户端启动/恢复或“关于畅聊”手动检查时，经现有更新接口读取新 iOS 版本；旧 build 2144 的提示可关闭，更新按钮跳既有 HTTPS 安装页。此处是源码路径与生产设置验证，实际旧机弹窗、覆盖安装旧聊天数据/钥匙串和后台提醒仍需设备反馈；用户的“使用没问题”未细分这些场景。

设置前态比较与写入未处于同一数据库事务，极短并发窗口仍有覆盖其他管理员改动的风险；本次没有发现冲突，发布前后完整前态和审计一致。未来应将 expected 校验置入设置事务。
