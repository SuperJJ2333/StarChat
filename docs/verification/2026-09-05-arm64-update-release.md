# 0.3.37 ARM64 更新发布

用户授权发布 APP 更新弹窗，仅构建/上传 ARM64。版本为 0.3.37+40，Android versionCode 2040。standard release，从源码构建；Dart/R8 混淆及资源收缩关闭，无加壳，使用既有正式证书。

- 更新逻辑/弹窗测试 16 passed；版本契约 2 passed；功能验证沿用同日刚完成的好友/二维码交付记录。
- ARM64 构建成功，APK 75,487,665 bytes，非 debuggable。
- 签名 SHA256 `b4784ac301d54add4157427713b136cb22cefd626e9c7a6092882e145c0b22f6`，与线上旧 APK 一致。旧线上 APK 与本地签名参照包的文件摘要也一致。
- APK SHA256 `bc52c6d7924e48523fa6686a071b784271bbe8cf503e921b6e6428983132e238`；首次 SCP 中断后通过 SFTP reput 续传，完成后才校验并发布。
- 公网完整下载流摘要与本地一致。
- 通过现有 scripts/publish_app_update.py 的受审计管理员 API 发布：PUT 200，GET latest 200，PUBLISH_RESULT PASS；latest_version 0.3.37，latest_build 40，min_supported_build 保持 3。
- 下载 URL：https://www.liuhetong888.com/downloads/ChatFlow-0.3.37-arm64.apk
- 只切换 latest-arm64.apk；latest-arm32.apk/latest-x86_64.apk 仍指向 0.3.36，旧包未清理。
- 服务器发布材料：/opt/starchat/releases/app-0.3.37-arm64/。本地完整输出：docs/verification/artifacts/2026-09-05/arm64-release/。

现有更新接口不识别客户端 ABI；“仅 ARM64”指本次只构建发布该架构安装包，不能保证旧的非 ARM64 客户端不显示弹窗。该限制在发布前已告知。

MI 6 保留 0.3.36 debug 安装及其数据，未安装正式包（签名不同不可直接覆盖）。发布后启动 APP，随后 UI 检查显示下载管理含 ChatFlow-0.3.37-arm64.apk；并未直接捕获弹窗或点击下载/安装，因此不把此检查记作弹窗截图验收。

回滚更新设置可将版本/build/URL恢复到发布日志 BEFORE 的 0.3.36/39/原URL，再将 latest-arm64.apk 指回旧包。设置变更继续使用管理员 API 与新的幂等键，不改其他业务数据。
