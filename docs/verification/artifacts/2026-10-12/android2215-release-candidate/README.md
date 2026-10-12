# Android2215 正式 ARM64 候选构建准备

本目录是独立准备任务，未执行Flutter/Gradle/Apktool/签名/ADB/服务器动作。仅新增本目录，不改已冻结android2215-release、root版本或产品源码。root负责产品修复、版本0.4.46+2215、正式构建和后续发布。本目录需非作者SPEC/domain→QUALITY/security后才作为实际builder输入。

## 设计与操作边界

`build-android-2215-arm64.ps1`沿538f90f6中的已运行2214正式builder最小适配：ARM64 standard release、真实lib/main.dart、三项HTTPS业务/Matrix/Getui dart-define和performance开关、保留完整图标字体、无Dart/R8混淆、独立source/output映射及仅owner cleanup。默认只有preflight，`-PreflightOnly`兼容；只有显式`-Execute`才进入真实构建。二者不可同时给。preflight不会创建build/run目录、subst、签名或调用设备。

源码pubspec与app_config必须都为0.4.46+2215；确认生产前态必须Android2214/iOS2213且时间不超过30分钟。所有源码/依赖/生成输入由`freeze_mobile_input.py`绑定，构建后及验证后重新核验。冻结后root HEAD也不能改变；证据提交安排在构建前或完成后。输出目录仅在本任务内，全新run ID，失败保留现场，不盲clean重跑。

依赖使用原`pub.dev` lock：当前SHA `a43833c8e7c3d6faa93d21babdc61dfe4b3563c7ac00912006f26daa8e0ecc5d`，216个hosted URL均pub.dev。先由root正常`flutter pub get --offline --enforce-lockfile`（不是本轮执行）恢复生成输入，再freeze，builder用`--no-pub`；源侧closure再次检查lock原始字节及host。旧registrant helper仅移除字节精确已知的dev-only Java块，构建后复核其余字节；不修改production注册。

## 工具与缺失旧锁屏工具的处理

- Apktool固定2.12.1，使用root已取得的`android2214-media-regression/tools/apktool_2.12.1.jar`，SHA `66cf4524a4a45a7f56567d08b2c9b6ec237bcdd78cee69fd4a59c8a0243aeafa`；文件夹中的2214是历史工具来源，不是新包版本。
- JDK17.0.20.8、Flutter C:/src/flutter、SDK build-tools36.0.0。完整decode→rebuild→`zipalign -P 16 -f 4`→现有固定75b31签名→apksigner(v2/v3/单signer)→签后`zipalign -c -P 16 4`。
- 新签名和语义工具从root已审538f90f6的`media-debug-packaging-tools/`精确Git字节复制到本目录`tools/`，由`candidate-tool-identities.json`锁定。签名调用必须显式`-Apksigner`与`-Execute`，缺key/DPAPI即拒绝，不生成新身份。本轮没有读取key/DPAPI内容或签名。
- 缺失的legacy `verify_lock_boundary.py`不被静默删除。root明确批准严格closure复用：旧签名APK575e24f4…af614/73336097B、本地旧receipt SHA a933c16c…c77f67、步骤final-lock-boundary exit0。基线冻结400个Android/third_party/calls/依赖输入；文本仅CRLF→LF，二进制保持原字节，主pubspec只容许精确2214→2215版本行。最终新包必须再次核对57个MainActivity全家族/整个call包smali逐字节及全aapt清单（只容许版本字段/element源行号）。增删类、类变化、重复DEX类、其它manifest变化、lock/native输入变化均拒绝复用。不是重新运行失落工具，也不是新手机锁屏或媒体UI通过。
- 2026-10-12T12:36Z当前原生source/旧包closure已只读核验；随后root升为2215，`current-closure-preparation.json`另记录新版本source闭包成功。最终新APK尚未存在，最终decoded检查仍待真正构建。

## root下一步（本轮不执行）

1. 合入本准备提交与双审，完成产品修复/版本递增并冻结root源码。协调独占mobile build目录及W/V映射；不抢占其他任务。选本目录下全新run ID。
2. 在root移动目录设置UTF-8/PYTHONUTF8与`PUB_HOSTED_URL=https://pub.dev`，按正常依赖流程执行`C:/src/flutter/bin/flutter.bat pub get --offline --enforce-lockfile`，检查lock SHA未变。运行本目录`freeze_mobile_input.py create --repo <实际root> --manifest <本次新mobile-inputs.json>`；所有参数均真实路径，不复制旧manifest。
3. 获取新只读生产版本检查时间，传入其实际UTC；运行builder不带Execute（或显式PreflightOnly）。必填`-Worktree`、`-MobileManifest`、`-ExpectedMobileManifestSha256`、`-ConfirmedProductionAndroidBuild 2214`、`-ConfirmedProductionIosBuild 2213`、`-ProductionCheckedAtUtc`；建议显式`-RunId`。
4. 双审和preflight通过后，root才以相同精确输入调用`-Execute`。从未变源码构建一次；每步退出码记录steps.tsv，失败即停。不要在签后重压缩/修改APK。builder生成的artifact.json使用实际SHA/大小/工具身份，不生成三gate批准。
5. 对新final.apk补齐以下真实门禁后，交已冻结android2215-release的`package_release.py`离线打包。默认不执行任何生产阶段。

## 最终三门禁与声明范围

| gate | 必须绑定的实际证据 | 不可替代 |
|---|---|---|
| shared_flutter | 最终源码/manifest/lock SHA；启动composition原RED→GREEN、相关回归、analyze和最终共享全量/经审覆盖闭包 | 旧2214全量不证明新初始化顺序；取消或未执行不得填pass |
| native_android | 新真实main debug媒体选择/图片/视频发送原复现与修复结果、实际包SHA/ABI/设备/启动轮次；未变native/storage用精确输入闭包复用并列范围 | 专用fixture或旧存储3项不证明AppHome初始化发送；x64模拟器不等于最终ARM64手机/全部ROM |
| final_apk | 本次ARM64正式source/final ZIP门禁、固定签名、版本/ABI/nondebug清单、16KiB ZIP alignment、独立重解包DEX/smali/manifest/lib+assets语义、native exports、最终锁屏closure、实际source/final APK SHA及大小、完整原始steps | zipalign不证明ELF 16KiB运行兼容；既有libcrypto4KiB/RELRO观察仍需如实记录，不冒称消除 |

三个报告内容须经root阅读并先SPEC/domain后QUALITY/security；共享/source/native证明的具体源码输入要与候选相同，变化部分不得沿用。gates.json必须使用实际source_commit/source_manifest_sha256/pubspec_lock_sha256/artifact_sha256、final_identity(package/ABI/version/build/signer/bytes)，每gate为真实相对报告路径+SHA。这里没有生成gates.json或新APK身份。轻量发布不再公网完整回拉重复验包，上传/元数据/平台隔离门禁由另一个已审发布框架处理。

## 本地准备验证

- `closure-red.log`：缺失新closure实施时6FAIL；实现后6PASS。`normalization-red.log`另证明二进制/manifest字面内容不能被过宽归一化隐藏，修正后完整7项closure通过。
- `test_candidate_preflight.py`只运行真实脚本preflight前缀，真实build尾部先替换为无条件throw；Python verify调用为替身，key/DPAPI为无效假文件，New-Item/subst为抛错替身。默认返回preflight、Execute才抵达不可执行的测试尾部、旧版本/工具漂移/closure失败拒绝，证明不启动构建。第一次失败是测试spy的PowerShell script scope归属，已保留`preflight-fixture-scope.log`，改用测试进程global计数，没有放宽builder。
- `git-export-boundaries.log`：精确Git blob导出11PASS/4.232s；26输入和8工具身份全部一致。`final-boundaries.log`：原工作树11PASS/3.425s（7closure+4preflight）。PowerShell两文件解析及7Python AST通过。未运行恢复signer/semantic的旧等价全套；工具Git字节完全相同且已有独审/旧真实包回放记录。
- 不执行全局verify.ps1：本任务只改独立构建工具/验证证据，无产品输入变化，全球render/build会写共享root并与父任务冲突。root仍负责最终产品门禁，不能把本11项称App测试。

准备阶段没有新APK、真签名、真preflight输入全链或设备通过；下一步是独立双审和root实际候选preflight。缺失/漂移停止，不能用旧通过日志补新身份。
