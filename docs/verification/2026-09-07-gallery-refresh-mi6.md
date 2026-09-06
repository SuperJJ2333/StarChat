# 最近图片刷新与Mi6 debug交付（2026-09-07）

## 根因与修改
photo_manager 3.12.0 的 FilterOptionGroup 默认 createTimeCond/updateTimeCond 在构造时记录 DateTime.now。原来进程级 final 实例只创建一次，因此再次打开即使清索引/重新查询也使用首次打开的截止时间，之后生成的截图被过滤；退出进程后新建条件才恢复。

修改仅将条件构造改为getter：每次原生相册索引查询都获得新的时间边界。仍保持创建时间倒序、MIUI无宽高视频兼容、预览缓存和分页；不需要清除用户图片缓存或重启APP。范围：device_gallery_source.dart；回归device_gallery_source_test.dart；设计布局和交互文案未变。

## 验证
新增实际MethodChannel边界测试：首次加载→稍后新增截图时间→清索引并再次加载，检查最近/视频/文件夹三个原生查询的创建和修改时间条件包含新时间，同时保持倒序。修复前RED明确createDate排除新图片；修复后PASS。
相册、选图页、扫码图库、视频首帧相关53项通过；Flutter analyze无问题；UI契约17组件330页通过。没有宣称重新跑全部1245项。
本地Figma账本/registry记录本次查询行为修复；远端工具不可用，远端未修改，已有聊天节点18:7，不伪造设计验证。

## Debug安装
用户授权保留数据、原debug签名覆盖。
- Mi6序列号cbd0156b；旧设备0.3.49-debug/2051。
- 新包0.3.50-debug/2052；standard ARM64；HTTPS Business/Matrix/Getui三个构建参数均为https://liuhetong888.com。
- APK路径：docs/verification/artifacts/2026-09-07/gallery-refresh/ChatFlow-0.3.50-arm64-debug-rebuilt.apk。
- SHA256：2c347062d1c305d11e3272a6a11b304d02cd0d5622aab48d74921d2692996d13；140822593字节。
- debug证书SHA256：34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1，与旧安装/本机密钥一致。
- Apktool2.12.1完整重建、build-tools36.0.0对齐/签名/验证；24912类、332原生库及Flutter资源逐项一致，清单语义一致；debuggable和debug kernel确认。
- adb install -r返回Success，无卸载/清数据/-d；设备APK哈希匹配。MainActivity启动，等待后进程仍运行，当前进程fatal markers为0。
- 当前分支为codex/chat-room-flow-fixes；未混入原目录钱包未提交改动；未替换线上APK。

真人验收：保持APP进程运行→打开并关闭最近图片→新截图→返回会话重新打开，最新截图应在首位；再生成第二张重复验证。自动化验证覆盖查询根因，不冒充真实相册新增延迟测量。

仓库 scripts/verify.ps1 最终 Verification: PASS（business/worker349通过、19现有外部服务条件跳过；mobile边界65通过；第三方Python弃用告警已记录）。
