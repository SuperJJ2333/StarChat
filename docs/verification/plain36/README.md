# ChatFlow 0.3.36 ARM64 普通源码构建

2026-09-05，用户授权重新打包：不反编译、不加壳、不添加构建防护。源码固定 b80049b3a062a07a02740bf553b026cdf5b2504b，导出副本独立构建；未纳入构建开始时未提交的 CallNotificationManager/call_ui_manager/matrix_call_adapter 等修改。

- APK：ChatFlow-0.3.36-arm64-plain.apk
- 大小：75,357,113 bytes（71.9 MiB）。
- SHA256：DDDD2D341BED39594D31D3ACE83BB5DACC2DB8F0656EEA6EBA9EDB6BA9FF4609
- 包名 com.liuhetong.mobile；版本 0.3.36；versionCode 2039；native-code 仅 arm64-v8a。
- 正式签名验证通过；证书 SHA256 b4784ac301d54add4157427713b136cb22cefd626e9c7a6092882e145c0b22f6，与线上原版一致；非 debuggable。
- Android isMinifyEnabled=false、isShrinkResources=false；Flutter 未传 obfuscate/split-debug-info，并传入 --no-tree-shake-icons。
- 不使用壳或新增加固工具，不反编译任何 APK。正式签名和正常 Release AOT/D8 编译保留；第三方预编译 SDK 自身已有的处理、通信加密和业务鉴权没有移除，因此不声称所有第三方二进制内部均无保护。
- 未生成 R8 mapping，DEX 中验证到原名 Lcom/liuhetong/mobile/MainActivity;（classes5.dex）。
- API、Matrix、Sygnal、Getui origin 保留 https://liuhetong888.com。
- pubspec.lock 与基线相比仅下载镜像域名变化；依赖版本与校验值一致。
- Flutter 构建耗时 168.2 秒、退出码 0。KGP 未来兼容性提示及 Java 旧 API/unchecked 提示保留于 build.log，没有抑制或为本次构建升级插件。

签名、版本清单及 SHA256 原始验证输出与本文件同目录。未部署、未替换线上包、未声称修复图库/摄像头或消除报毒。需要用户在实际设备安装验证。
