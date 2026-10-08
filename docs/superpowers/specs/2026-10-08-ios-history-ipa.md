# 最新修复 iOS 待企业签名 IPA 规格

用户2026-10-08要求打包iOS IPA并自行企业签名。本次授权包括在已有项目GitHub CI构建所需的候选分支推送、完整设备编译、相关原生运行门禁、下载与本地验包；不包括App Store/TestFlight上传、企业证书导入、生产静态下载/设置/弹窗发布或main合并。

源为已双审/全量验证的历史/弱网/语音候选3c37b529，文档父6ae1357a。新版本0.4.36+2205；保持Bundle ID com.liuhetong.liuhetongMobile、iOS16.0下限、SQLCipher/密钥与账号存储、VoIP/audio/remote-notification和原生权限。更改只有成对版本、无签名构建/验包工具及CI，不修改聊天、财务或鉴权行为。原共享全量证据按输入/影响复用，不再重复Windows全量。

输出须为真机arm64 release Runner.app完整Payload IPA。macOS15、Xcode26.3、Flutter3.44.9固定；官方pub.dev enforce-lockfile，记录生成Podfile.lock。禁止移除生产插件、把模拟器包改名为IPA、把旧2194/2204包改文件名、在候选中引入任何企业私钥/profile。预期推送/Keychain等entitlements作为独立交接文件，未签包不宣称已签权益。

实际门禁：Ruby权限hook无skip、ObjC权限实现二进制检查、device MachO/CFBundle identity、SQLCipher加载顺序及key/blob open/read/write/close/bytes六符号、资产SHA、Payload结构/完整性与产物SHA。在独立模拟器合成测试宿主运行现有SQLCipher/WAL、Keychain和新增分块迁移原生运行门禁；扫描器MLKit无模拟器arm64的既有排除只能用于测试宿主，完整设备产物保留scanner。

CI日志/工具/运行ID、源码SHA/锁/版本与产物身份写入任务证据。交付IPA和entitlements/build manifest供用户回签；回签后签名Team/App ID/Keychain及保留数据覆盖升级是另一验收阶段，不用同Bundle ID替代实际验证。

新增永久integration_test/ios_timeline_storage_migration_native_test.dart测试入口，复用既有迁移断言并显式要求iOS。Flutter3.44.9只把integration_test目录下目标识别为device integration；RUNNER_TEMP目标供flutter test会走host widget，不可作为iOS运行证据。此测试入口不改变产品行为。
