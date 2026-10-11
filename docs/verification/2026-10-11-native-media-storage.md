# R8 原生媒体目录候选

root 所有权：Android MediaStoragePolicy/MainActivity 接线/JVM测试；iOS IOSMediaStoragePolicy/AppDelegate/PBX/XCTest；跨平台 integration_test/native_media_storage_test.dart。与持久任务 owner 冻结 channel 契约，未编辑其 store/recovery。

`chatflow/media_storage.pendingMediaDirectory` 无参，返回固定 path、availableBytes、protected、backupExcluded。Android 使用 credential-encrypted context 的 noBackupFilesDir/pending-media-v1，拒绝 device-protected context、目录链接和非固定子路径；该目录由平台排除自动及设备迁移备份，参见 [Android Auto Backup](https://developer.android.com/identity/data/autobackup)。不修改应用全局 backup 配置，不使用共享外部目录。

iOS 使用 Application Support/pending-media-v1，设置 CompleteUntilFirstUserAuthentication 及 isExcludedFromBackup 并读回。`sealPendingFiles` 仅接受64位小写hex scope/sourceId，对固定 manifest-v1.db 及 journal/WAL/SHM、sources 下固定 .bin/.bin.part 设置/复核策略；拒绝符号链接和任意路径，不从外部rename原件。Dart持久owner负责目录内分块复制、flush与内部rename，并在queued之前调用seal。目录规则不能替代新增文件检查，Apple明确部分保存操作会重置备份资源值，参见 [备份优化指南](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)。

另提供固定 Documents/chat-media 与 Caches/chat-media 目录分组的保护/备份排除方法，保留现有文件；该方法在缓存调用方接入并经平台验证前不声称旧缓存已治理。pending域与可淘汰cache独立，未添加删除/迁移API。上述待发本机数据不承诺跨设备云备份恢复。

验证：先新增JVM测试，原代码因缺 MediaStoragePolicy 编译RED（native-storage-red.txt，非行为RED）；实现后4存储专项+8相邻FGS=12PASS，Gradle exit0。验证固定目录、device-protected拒绝、非法ID/缺文件拒绝、manifest/WAL/source内容保持。Android app/插件原生编译已执行，跳过Flutter APK构建；JVM不冒充真机加密/备份抽取。Java17.0.20+8、Gradle9.1.0、Robolectric4.14.1/API35，沿用现有固定依赖。已有Gradle弃用、第三方测试编码/弃用警告留在日志。

Flutter集成测试仅analyze通过，尚未在手机/模拟器执行。新增iOS两个XCTest及生产Swift尚未在Windows编译，必须在macOS/iOS门禁验证；缺helper/保护false时持久任务拒绝准入，无cache回退。SPEC→QUALITY及实际接线仍待。

证据：artifacts/2026-10-11/im-reliability-implementation/native-storage-*。实现时间约12:17–12:26 UTC+08，单步精确起止未全记录。未打包、未分发、未改变服务器。
