# R8 原生媒体目录候选

root 所有权：Android MediaStoragePolicy/MainActivity 接线/JVM测试；iOS IOSMediaStoragePolicy/AppDelegate/PBX/XCTest；跨平台 integration_test/native_media_storage_test.dart。与持久任务 owner 冻结 channel 契约，未编辑其 store/recovery。

`chatflow/media_storage.pendingMediaDirectory` 无参，返回固定 path、availableBytes、protected、backupExcluded。Android 使用 credential-encrypted context 的 noBackupFilesDir/pending-media-v1，拒绝 device-protected context、目录链接和非固定子路径；该目录由平台排除自动及设备迁移备份，参见 [Android Auto Backup](https://developer.android.com/identity/data/autobackup)。不修改应用全局 backup 配置，不使用共享外部目录。

iOS 使用 Application Support/pending-media-v1，设置 CompleteUntilFirstUserAuthentication 及 isExcludedFromBackup 并读回。`sealPendingFiles` 仅接受64位小写hex scope/sourceId，对固定 manifest-v1.db 及 journal/WAL/SHM、sources 下固定 .bin/.bin.part 设置/复核策略；拒绝符号链接和任意路径，不从外部rename原件。Dart持久owner负责目录内分块复制、flush与内部rename，并在queued之前调用seal。目录规则不能替代新增文件检查，Apple明确部分保存操作会重置备份资源值，参见 [备份优化指南](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)。

另提供固定 Documents/chat-media 与 Caches/chat-media 目录分组的保护/备份排除方法，保留现有文件；该方法在缓存调用方接入并经平台验证前不声称旧缓存已治理。pending域与可淘汰cache独立，未添加删除/迁移API。上述待发本机数据不承诺跨设备云备份恢复。

验证：先新增JVM测试，原代码因缺 MediaStoragePolicy 编译RED（native-storage-red.txt，非行为RED）；实现后4存储专项+8相邻FGS=12PASS，Gradle exit0。验证固定目录、device-protected拒绝、非法ID/缺文件拒绝、manifest/WAL/source内容保持。Android app/插件原生编译已执行，跳过Flutter APK构建；JVM不冒充真机加密/备份抽取。Java17.0.20+8、Gradle9.1.0、Robolectric4.14.1/API35，沿用现有固定依赖。已有Gradle弃用、第三方测试编码/弃用警告留在日志。

Flutter集成测试仅analyze通过，尚未在手机/模拟器执行。新增iOS两个XCTest及生产Swift尚未在Windows编译，必须在macOS/iOS门禁验证；缺helper/保护false时持久任务拒绝准入，无cache回退。SPEC→QUALITY及实际接线仍待。

证据：artifacts/2026-10-11/im-reliability-implementation/native-storage-*。实现时间约12:17–12:24 UTC+08，单步精确起止未全记录。未打包、未分发、未改变服务器。

独立首审发现两项边界：Swift未拒绝目录占据普通文件名；两端exists跟随链接会漏过悬空optional WAL/part。Android旧实现新增专项得到6项中1项预期行为RED，修复为NOFOLLOW_LINKS属性类型检查后6存储+11相邻原生测试=17PASS（native-storage-boundary-*-test/green.txt）。首次错误任务名testDebugUnitTest在flavor下歧义，留native-storage-boundary-red.txt作为环境失败，不算行为RED。iOS改用lstat并增加同类XCTest，仍待macOS编译/执行。文件操作限定固定sandbox，无法据此声称对同进程恶意并发替换提供原子防护。新增测试nullable警告改为requireNotNull，历史第三方/Gradle警告保留。

新增独立macOS工作流im-native-storage.yml，精确源码与锁文件存证，真实XCTest读回目录策略；诊断host仅排除当前不支持arm64 simulator的mobile_scanner/MLKit，最终生产包仍须全插件构建。尚未执行前不标PASS，亦不替代真实设备备份/锁屏验收。

## 2026-10-11 13:12+08 后续结果

前文为分阶段历史结果。Android完整JVM89PASS之后改用Os.lstat，冻结41c86084。Robolectric4.14.1默认lstat对不存在文件返回mode0，与真实ENOENT不同；以实际host NOFOLLOW属性实现API24 Posix及API35 Linux shadows，最终12PASS。中间final.txt为Kotlin静态override编译失败，正式绿色证据是android-native-storage-api24-35-posix.txt，不混用。API28现有模拟器运行仅含合成文件的Os.lstat shell probe，regular/directory/dangling/ENOENT PASS，已清理其固定临时目录；此证据不能替代真实私有目录及备份验收。独立审查41c86084 SPEC→QUALITY PASS。

iOS run38112151641（bdbaab66）编译及运行成功但3项XCTest失败，不是PASS。run38113138721仅提取该次xcresult：后两例重复目录创建Code516，首例Failure.unavailable。原始artifact SHA65778296a8fa6eca633adaca1e29b0e7024e3982ea79278852dea352eb0e6046；诊断artifact SHAb0c0c12cbba2b5a249bb73236b144c940c169d87fc4c7255d76ebd38b5d1fb9e。c8dba609保留已有目录并复核策略，新增重复调用和能力诊断，内部错误区分保护/备份/容量，channel对外仍统一脱敏错误。run38113845125继续验证；没有降低iOS保护门禁或把模拟器缺能力直接视为生产通过。

41c86084最终Android完整JVM执行：Gradle exit0，13类95项中**94 PASS / 1条件skip / 0失败**。skip为历史DeltaApplier真实签名APK互通夹具未提供，不是存储测试；存储12项全执行通过。前文“89PASS”是未扣除同一历史skip的总用例数，修正为88PASS/1skip。原始第一次全量命令误排除不存在的packJniLibs任务导致配置失败，改为仅排除Flutter编译后完成；两日志分别full.txt及full-corrected.txt保留。最终XML统计和hash见android-native-41c86084-results.json；不以Gradle success推断所有条件用例执行。

另外核查到Runner无app级PrivacyInfo.xcprivacy。新增d17689f2：低空间准入对应DiskSpace/E174.1，app私有文件metadata对应FileTimestamp/C617.1，既有原生通话/下载内部偏好对应UserDefaults/CA92.1，并接入Runner资源。理由依据[Apple required-reason定义](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)和[TN3183](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest)。未声明整个产品不收集数据或代替App Store隐私标签/SDK审计；磁盘信息仅用于本机准入，不上传。静态门禁真实缺manifest RED→20项相邻PASS；新增XCTest要求实际Runner bundle内有对应声明，等待下一原生CI，未提前标通过。

## 13:50+08 能力定位

第二轮run38113845125（c8dba609）已结束，4项策略成功路径XCTest因`protectionUnavailable`失败；能力诊断本身完成。诊断run38115523536只解析既有xcresult并提取附件，没有再次构建。artifact11693053043 SHA256 `dda772a2af0c25c23714521a8fe22400a6a0769ac1cd17d8c8442356c09cf95c`；原始附件读回`protection=nil, excluded=Optional(true), importantCapacity=Optional(35125567488), capacity=Optional(35125567488), systemFree=Optional(35125567488)`。这是该iOS26模拟器未提供文件保护读回的证据，不是iPhone数据保护失败的证据。生产严格校验保持，依赖真实保护能力的成功路径不能标PASS；独立owner正在区分模拟器显式能力缺口和仍可执行的路径/失败拒绝门禁。重复目录源码修正尚不能靠本轮提前失败的测试声称已通过。

## 第三轮真实 XCTest：4 PASS / 4 SKIP / 0 FAIL

run38116935821，源码11904803，2026-10-11T06:05:43Z开始、06:16:43Z工作流完成。真实iPhone15模拟器iOS26.2（23C54）、arm64、macOS15.7.9，artifact11693856437 SHA256 `94b5510b9c1615fbe6b3a8e071690b290ff186b1163c94c3e86521d2d7d1857d`，原生编译与测试工作流success；xcresult计8项，**4PASS/4SKIP/0FAIL/0expectedFailure**。成功的是能力探针、实际production failclosed且重复调用保留内容、路径/符号链接/类型检查，以及Runner实际bundle包含所需隐私声明。4项依赖Data Protection成功路径，仅在Simulator且实际设置后保护nil、备份排除true和容量非负条件同时成立时显式skip；真实设备没有该skip分支。生产apply仍无条件调用原entry guard并设/读回保护，未提供替代保护参数或cache回退。

root逐行独立复核f0c629e4的原guard提取和能力条件，保持原语义；Swift实际编译由上述CI补齐。d17689f2隐私声明另经独立审查C617.1/CA92.1/PBX接线通过，E174.1在持久任务冻结850710bd+3b8e1bd的真实低空间准入及用户可见错误路径核验后通过，容量不进入manifest/日志或设备外。该结论不关闭新发现的same-txid准备竞争，也不替代整个产品隐私审计。

日志保留第三方Pod最低版本警告，以及photo_manager的PrivacyInfo处理警告；本次Runner manifest实测存在不能代替最终全插件IPA内各SDK隐私资源检查。后续完整iPhoneOS unsigned包仍需独立构建。4项skip不是手机保护/备份排除/覆盖升级验收，最终签名与真机门禁继续保留。
