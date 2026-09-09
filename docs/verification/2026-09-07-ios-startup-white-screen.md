# iPad 首次启动持续白屏调查

## 真机根因证据（19:19，更新）

Windows USB 配对成功，设备 iPad15,6 / iPadOS 26.6.1，查询目标 bundle 确认已安装 0.3.47（6）。用户重新打开后，目标进程 PID 1405 在 19:19:08 记录 `Bad state: SQLCipher library is not available, please check your dependencies!`，随后 `Unhandled Exception`，堆栈经过 Client.init、MatrixClientFactory._openPersistentClient、create、main.dart:41。这确认白屏直接由 runApp 前 SQLCipher 初始化失败造成；此前加载顺序假设已有真实故障支持，修复效果仍需升级复验。

仅保留目标 PID 的脱敏日志：artifacts/2026-09-07/ios-device-logs/runner-startup-redacted.log。同名 Runner 的其他进程记录已剔除。采集工具 pymobiledevice3 11.9.0 位于隔离 venv，未修改项目依赖。

签名工作流增加实际 IPA SQLCipher 存在和优先加载检查，失败时阻止上传。候选只发布原版源码加链接顺序修复，模拟器诊断改动不混入该包；真实 iPad 升级后验证首屏。之前诊断运行34112885318已确认 cancelled。

候选提交 `800a5290d03f99f4ada05137da2bb3e7e6d47895` 已推送至原签名分支。最终 tree 相对父提交仅两个文件、23行新增（pbxproj三处各5行，工作流校验8行），git diff --check与工作流 YAML/内嵌 Python 语法检查通过。原版 IPA 加载顺序检查再次按预期失败。独立规格/质量安全复核未发现阻断，但明确真机升级验证仍未完成。构建：https://github.com/SuperJJ2333/StarChat/actions/runs/34116249901 ，job101723649752，开始时状态in_progress。

### 0.3.47（7）候选构建与上传结果

运行34116249901最终success。推送测试、IPA构建、签名/生产APNs/iPad权限校验全部通过；实际IPA在云端和本地独立Mach-O解析均输出SQLCIPHER_LOAD_ORDER_PASS（旧包相同检查失败，新包通过）。11:32:11 UTC日志确认UPLOAD SUCCEEDED with no errors。该结果确认候选上传成功，仍不等同于Apple处理完成或真机首屏验证通过。

本地包：artifacts/2026-09-07/ios-build/signed-34116249901/liuhetong_mobile.ipa；SHA256 `d3bb9e8aabf639456ca7c17ae90c45de5ecc194f2bc9b1656c092aa5c73f3b7c`。构建日志：artifacts/2026-09-07/ios-secrets-check/job-101723649752.log。已请用户通过TestFlight保留数据升级到（7），再用USB采集验证。后续capture_bundle.py以目标应用安装路径过滤，避免同名Runner的其他应用混入。

以下保留调查过程；其中“未获取真机日志”描述是早期状态，已由上面证据更新。

用户确认：点击图标后一直白屏，未出现登录页，没有自动退出。受影响构建为当前交付的 0.3.47（6）（尚待用户确认设备显示版本）。此报告取代先前对“闪退”的初步描述。

已知代码路径：main 在 runApp 前 await SharedPreferences、ThemeController.load、MatrixClientFactory.create。后者读取 Keychain 数据库密钥并通过 SQfLiteEncryptionHelper 初始化 SQLCipher，随后 client.init。首次无登录会话时，不进入 Olm 会话初始化。

假设：iOS SQLCipher 符号解析选中了系统 SQLite，applyPragmaKey 的 cipher_version 校验抛错，错误在 runApp 前发生，无 UI 呈现。

证据：已交付 IPA 的 Runner Mach-O LC_LOAD_DYLIB 同时包含 /usr/lib/libsqlite3.dylib 和 @rpath/SQLCipher.framework/SQLCipher，系统 SQLite 排在前面。SQfLiteEncryptionHelper 的 iOS 分支使用 DynamicLibrary.process()。当前依赖 sqlcipher_flutter_libs 0.6.8 的 README 明确说明 firebase_messaging 等引入系统 SQLite 时存在符号冲突风险。以上尚不等同于运行时根因确认。

云端复现：https://github.com/SuperJJ2333/StarChat/actions/runs/34109535807 ，提交 5ededea944d5d2431f9e40836bdc7f9e4d907984。独立工作流构建 iOS26 iPad 模拟器 Debug app，首次启动45秒，保存 startup.log 与 startup.png。没有再次上传 TestFlight 或修改生产数据。Debug 模拟器不能替代 TestFlight 真机 Release 验收。

下一步：依据原版启动日志确定故障边界，单一变更验证；若确认为 SQLCipher 解析，则限定到准确的 bundled framework，保留 cipher_version 检查和原有密钥/数据库格式，不清库、不降级明文。

## 后续诊断结果（尚未解决用户白屏）

- ARM 模拟器运行34109535807、Intel运行34110506896均在编译时失败：Framework Pods_Runner not found，未启动应用。架构切换没有解决该错误，不能认定架构是根因。
- 补齐标准 CocoaPods Debug/Release xcconfig include 后，A/B运行34112537017仍在相同编译环节失败。产物保存在 artifacts/2026-09-07/ios-build/evidence-34112537017，包含实际生成Podfile和Debug.xcconfig；没有startup.log或截图。
- 加载顺序检查脚本对原始 IPA 失败，sqlcipher-order-red.log已保存。但该检查是配置风险证据，不能替代真实运行时根因证据。
- 本地及独立候选分支codex/ios-startup-repair-20260907已设置Runner三种配置SQLCipher优先链接。未上传新的TestFlight包；用户设备仍运行原先构建。
- 请求只读复查后确认A/B脚本不能整份还原pod install前的pbxproj；已改为Ruby xcodeproj仅恢复链接参数，保留生成集成。最新运行34112885318、提交aa67b3028ee777404c75c036291b9cad5833b4bd在执行。审查同时要求人工确认截图，Matrix初始化日志不能单独证明首屏可用。
- 仓库verify.ps1本轮止于OpenAPI drift（packages/api-contracts/openapi/liuhetong-v1.yaml）；工作区存在并发钱包/业务接口改动，本次未触及相关文件，不为通过检查而覆盖它们。完整日志startup-repair-repository-verify.log；不得声称本轮全门禁通过。
- 已请求用户通过USB连接iPad并信任Windows，以直接获取真实设备启动日志。本机当时未检测到Apple设备服务或已连接iPad，pymobiledevice3也未安装。

仍未确认首屏前哪个await失败；无真实iPad运行日志，无模拟器成功启动证据，不应声称已修复。

用户随后转发诊断失败邮件；已说明它不是Apple审核拒绝。为停止重复无效构建，已向最新运行34112885318发送取消请求（API成功接受）。保留候选改动和失败证据，暂停该模拟器路径，等待真实iPad USB连接与信任后采集启动日志。未重新签名或发布候选修复。
