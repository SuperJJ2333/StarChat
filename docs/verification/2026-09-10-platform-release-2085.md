# 0.3.81 / 2085 双端候选与企业签名交接

## 范围与发布状态

用户最新决定：先交付 IPA，企业签名回传后再安排双端过渡发布。本轮准备 Android 正式候选与 iOS 重签输入，不修改生产镜像、更新设置、下载站或 OTA manifest。2084 的已发布状态见 `2026-09-10-mobile-0380-2084-release.md`，不能把“本轮未发布2085”写成“线上没有更新”。

旧 iOS 0.3.69/2073 对应源码80d2510e，`latestAppUpdate()` 请求 `/app-updates/latest`，不携带平台；与旧 Android 请求无法可靠区分。现有默认Android投影仍会被旧iOS取得。因此此前2084报告“平台接口上线即完全杜绝iOS串投”的结论仅适用于发送并验证platform的新客户端，不适用于2073。不得从UA、设备名推测平台。签名回传后的过渡发布须处理该限制，不能仅更新iOS设置宣称旧版本隔离完成。

## 实现

- U01：API 两端均返回 `platform`；新增中性 `download_url`，保留兼容 `apk_url`；使用已有独立设置键，鉴权不变；OpenAPI同步。
- U02/U03：Flutter 明确请求自身平台，拒绝缺失/错误的platform；自动弹窗及关于页共用接口、解析与下载函数。关于页发现新版本的分支用finally恢复检查状态，关闭弹窗后可再次检查。
- U04/U05：版本统一0.3.81+2085，两端最终候选构建与包内核验结果见下文。本轮不推送更新。
- U06：统计助手复用最新已确认HTML，源SHA256 `89eab23270dc87ce6fd07715d9abb2606455d94ce1fc16cd56d2deeaeeafb9d5`。两个最终包内哈希均已核验一致。
- U07：2084原生语音、账号隔离存储、broker登录、视频压缩实现未修改。Redmi用户已反馈两类语音正常、历史可见；iPhone15（用户原描述iOS26.6）仍需企业签名覆盖升级后真机验收，不将模拟器结果写作实机通过。
- U08：保留旧wire兼容不等于旧OS可识别；生产过渡延期到企业签名回传。

## 验证记录

证据目录：根仓库 `docs/verification/artifacts/2026-09-10/platform-release-2085/`。

- 客户端平台路由先出现4项预期失败，修复后通过；关于页回归证明关闭弹窗后仍有加载指示器、无法重查，两端均先失败，finally修复后通过。
- 移动端路由、弹窗、关于页重复检查、统计助手32项通过（mobile-focused-green.log）。
- 服务端18项通过。初次测试误导入根仓库editable包，后设置当前worktree的PYTHONPATH并打印app.__file__确认；有效测试耗时43.07s，exit0。合并并行后台改动后再次验证main：18项通过、65.28s（server-main-integrated.log），合并后的OpenAPI check通过。
- Flutter analyze通过。全量1928通过、1失败，唯一失败是既有视频测试临时目录未创建，干净worktree缺该目录；补recursive mkdir后专项3项通过（video-test-fixture-green.log）。不改变视频业务逻辑。
- 完整scripts/verify.ps1在2085隔离分支通过（repository-verify.log，exit0）：Infra141、Getui28、Bot9、API/Worker1714通过46跳过（937.26s）、移动边界70通过、UI契约、AST204、迁移唯一head0063/离线升级、OpenAPI与Compose通过。跳过保持测试原有环境条件，未添加skip。本轮未修改的既有DeprecationWarning仍由测试报告显示。之后main合入另一任务0064后台扩展；本任务对合并main补跑18项更新接口与OpenAPI检查，未把分支全量结果冒充合并后全仓重跑。
- 独立只读审查：先规格后质量安全，未发现代码阻塞；要求统一计划中的延期发布描述，已修正。审查确认统计asset声明与共用加载路径，但未代替包内检查或真机测试。

## 企业重签要求

IPA候选用于企业重签，不是可直接企业分发的包。保留bundle ID `com.liuhetong.liuhetongMobile`、版本2085、音频/VoIP/推送后台模式、SQLCipher及Flutter资产。回传后核验签名身份与原安装兼容性、entitlements、嵌入库和统计资产，再安排覆盖安装及语音/切号实测；不要卸载旧应用或清空聊天数据。

重签必须延续现有企业安装的有效签名身份与Keychain访问关系，不能把候选包的App Store团队前缀原样套到企业profile，也不能任意更换企业团队。否则即使应用能安装，也可能无法访问原加密数据库密钥。有效entitlements必须由企业profile授权，回传后再逐项核验。

## Android已验证候选

文件 `android/ChatFlow-0.3.81-build2085-arm64.apk`，78,277,662字节，SHA256 `83ba7e183aff595dc50e3fefbfbb6c2a8dcd00dd24068e38484ec3076bb7aec5`，包名com.liuhetong.mobile，0.3.81/2085，仅arm64-v8a。固定发行证书 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。

源码APK→Apktool2.12.1重建→zipalign36.0.0→签名→重解包验证：25,271类一致、338项原生库/资产零变化、清单语义一致，源码和最终APK发行门禁通过，包内统计HTML与预期SHA一致。构建首次失败源于使用`--no-pub`时保留测试用GeneratedPluginRegistrant；恢复完整Flutter release tooling生成后通过，未手工编辑注册文件。Android构建工作树4c199ae1与iOS构建083ad16f的整个apps/mobile_flutter源码diff为空。此包尚未发布，不能覆盖不同包名的Redmi debug安装。

## iOS已验证重签输入

`ChatFlow-0.3.81-build2085-for-enterprise-resign.ipa`，59,220,826字节，SHA256 `70f0a8664db81f364edff50d3e8b4a85e983dbf05d65b04a2be82121f3407faa`。构建源083ad16f，GitHub Actions `34485661400` 成功；下载ZIP摘要与GitHubartifact摘要 `8f9c389963e06cf9b899dfa5bf5006e9b2bc9000e6b2effe84539e3a9fe59013` 一致。

包内0.3.81/2085、bundle ID正确，最低iOS16，zh-Hans/en本地化、audio/voip/remote-notification、麦克风描述、SQLCipher存在。统计HTML SHA与Android及源文件一致。CI执行codesign deep/strict及生产APNs、SQLCipher链接顺序检查；本地另读取Info/profile/资产（ios-candidate-metadata.json），没有把Windows元数据检查冒充codesign验证。当前签名是App Store团队HY9Q7Q35S5，enterprise=false，仅供企业重签。

同源原生兼容CI `34485661361`：完整生产插件编译通过；iPhone15的iOS18与iOS26模拟器均通过corrected media/direct-room、native media/seed、跨新应用进程retained history三个步骤。iOS18下载证据为native18/seed.log（20通过）、verify.log（3通过）；iOS26的native26/seed.log（20通过）、verify.log（3通过）同样已下载确认。模拟器因MLKit缺arm64 simulator slice而仅在诊断包排除mobile_scanner；完整生产编译与签名候选均包含它。模拟器不验证真实听筒声学输出、企业签名Keychain连续性或生产双设备顶号，用户所述iOS26.6真机验收仍待签名回传。

## 用户追加：保存聊天记录后原账号重登与L04

L04是`matrix_login`阶段诊断码，不代表删除或保存聊天数据失败。2085继承2084的同设备重新认证：保存退出只暂停客户端；再次登录取得新broker grant；原userID/deviceID存在时用MatrixApi交换token、softLoggedOut+init恢复原身份，并重新登记原公钥，避免对保留的SDK对象直接调用普通Client.login。

独立审查追加重跑13项通过：retained_device_reauthentication_test（4）、retained_account_login_test（3）、history_continuity_flow_test（6）。覆盖suspend后旧对象loggedIn=false/true、恢复对象仍loggedIn、同device_id、原OlmManager上传、零logout调用、上传失败拒绝完成。部分测试使用fake身份指纹，legacy history flow不是实际broker完整闭环；不能据此承诺iPhone实机公钥不变或L04绝不出现。服务端token交换、SDK初始化、身份校验、公钥登记发生异常仍可返回L04。用户现有2073不能当作已安装2085；企业重签回传后需在原机执行“保存退出→原账号重登→历史与新消息”验收，保留错误阶段诊断但不记录token/消息/密钥。
