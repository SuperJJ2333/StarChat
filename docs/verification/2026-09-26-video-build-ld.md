# 2179 视频诊断与雷电 Debug 验证

## 交付身份和范围

- 源码：`codex/auth-login-2178` / `d7d09ffb3f5b61c0ca1475c92e14dd182b7a7171`；基线 `9ad2eb77`。源码实现、规格审查与质量/隐私审查完成。
- APK：`0.4.13+2179`、`com.liuhetong.mobile.debug`、`arm64-v8a`、Debug kernel。最终文件：`artifacts/2026-09-26/video-build-ld/run-20260926-040300-ld/final.apk`，145658155 字节，SHA256 `0dd6ba52dc7cc4c8414ebf737d015963461395679fe4882091f3b251c32e070b`。
- 固定签名 SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，单一 signer，v2/v3 验证通过。`pubspec.lock` SHA256 `a2af1ef677f2bee3af4d012d15eb5dc2492d220bf66eabb27ccf62c17fd733fc`；构建过程未改锁文件。
- 仅在 `emulator-5556` 安装；未发布生产/API/iOS，也未安装到 MI 6。装机前此模拟器未列出旧主包，本次没有执行卸载或覆盖。

## 修改文件清单与诊断流

| 文件 | 目的 |
| --- | --- |
| `apps/mobile_flutter/lib/core/app_config.dart`、`pubspec.yaml` | 2179 编译基准与 Android 已知 ABI offset 精确归一化，普通四位 build 原样保留 |
| `apps/mobile_flutter/lib/core/performance_trace.dart` | 每条 `video_prepare` trace 至多保留 normal/aggressive 两档类型化尝试 |
| `apps/mobile_flutter/lib/core/performance_trace_model.dart` | 本地两档摘要、失败未完成区间及实测瓶颈分类；上传 `toJson()` 不变 |
| `apps/mobile_flutter/lib/features/matrix/video_transcode.dart` | 每档真实计时、封闭结果记录、非有限时长保护与临时产物清理 |
| `apps/mobile_flutter/third_party/video_compress/android/src/main/kotlin/com/example/video_compress/VideoCompressPlugin.kt` | 原生失败/取消返回固定错误码与空详情 |
| `apps/mobile_flutter/third_party/video_compress/lib/src/video_compress/video_compressor.dart` | 固定错误码映射为类型化异常，不打印原生文本 |
| `apps/mobile_flutter/test/core/app_config_test.dart`、`tests/mobile/test_app_build_contract.py` | 运行时四位 build、关于页、更新与诊断版本注入契约 |
| `apps/mobile_flutter/test/features/matrix/video_compress_plugin_error_test.dart`、`video_transcode_performance_trace_test.dart` | 原生错误映射、两档记录、隐私、异常时长和清理回归 |
| `apps/mobile_flutter/test/performance/performance_trace_test.dart`、`performance_bottleneck_classifier_test.dart`、`performance_trace_upload_test.dart` | 有界/幂等/分类与本地快照和上传出口隔离 |
| `docs/performance/chatflow-performance-diagnostics.md`、`docs/superpowers/plans/2026-09-26-video-transcode-build-ld.md` | 扩展既有诊断手册与执行方案 |
| `docs/workflow/current-state.md`、`docs/workflow/tasks/2026-09-26-video-transcode-build-ld.md`、本报告 | 恢复入口、阶段/证据台账与交付限制 |

数据流为：`video_prepare` 用户操作 → 既有 `PerformanceTrace` → 真实阶段与至多两档转码计时 → 既有 `PerformanceMetrics` 本地有界快照；同一个完成记录进入既有 `ChatDiagnostics` 的采样批次，其上传 JSON 不带新增的本地字段。没有新建平行遥测或上传网络请求。完整操作列表、其他分类规则与各模块审计沿用[诊断手册](../performance/chatflow-performance-diagnostics.md)。

## 改动验证

| 门禁 | 结果 | 证据 |
| --- | --- | --- |
| 四位 build 测试先红后绿 | RED exit 1：2179→179；GREEN exit 0：8 项。关于页、split ABI、强更比较覆盖 | `test/core/app_config_test.dart` |
| 原生通道测试先红后绿 | RED exit 1：旧插件吞异常且输出原文；GREEN exit 0：5 项 | `test/features/matrix/video_compress_plugin_error_test.dart` |
| Trace/分类/视频策略 | RED exit 1（新 API/失败区间缺失）；GREEN exit 0：51 项聚焦。非有限视频时长另有 RED exit 1 → GREEN exit 0，5 项。上传边界 11 项通过 | `test/performance/`、`test/features/matrix/video_*` |
| Flutter analyze | exit 0，`No issues found` | `flutter analyze --no-pub lib test` |
| Matrix 测试 | exit 0，2115 通过、9 跳过 | `flutter test --no-pub test/features/matrix` |
| 完整 Flutter 测试 | 最终 exit 0，4333 通过、9 跳过 | `artifacts/2026-09-26/video-build-ld/flutter-test-full-final.log` |
| Android 插件编译 | exit 0，`:video_compress:compileDebugKotlin`；仅既有弃用/空值警告 | Gradle 离线 Debug Kotlin 编译 |
| build 契约 | exit 0，3 项通过 | `py -3.12 -m pytest -q tests/mobile/test_app_build_contract.py` |
| 仓库总门禁 | exit 0，`Verification: PASS`；其中 Business API/Worker 2905 通过、75 跳过，移动端 Python 边界 109 通过、1 跳过 | `artifacts/2026-09-26/video-build-ld/verify.log` |
| Apktool 常规重建与验包 | 18/18 步 exit 0；DEX 类语义 27317/27317 相同、339 项原生库/Flutter 资产 SHA 相同、资源表重建、manifest 语义相同 | `artifacts/2026-09-26/video-build-ld/run-20260926-040300-ld/steps.tsv`、`verification.json`、`identity.log`、`apksigner-verify.log` |

完整 Flutter 测试第一次执行 exit 1：运行期间根据规格审查加入“取消操作不属于失败转码瓶颈”的测试，但该进程已加载旧模型。代码固定后单项复测 exit 0，再完整重跑 exit 0；首次日志保留在 `flutter-test-full.log`，没有把首次失败写成通过。

## 雷电模拟器验收

`adb -s emulator-5556 install -r -t --no-streaming final.apk` exit 0 / `Success`；`am start -W` exit 0，登录页正常显示，进程仍运行。已安装包的 `dumpsys package` 返回 `versionCode=2179`、`versionName=0.4.13`。通过 Debug VM `getObject` 读取运行时 `AppConfig.appBuildNumber=2179`，确认没有再截成 179；关于页 `Build 2179` 有 Flutter widget 测试。截图为 `artifacts/2026-09-26/video-build-ld/run-20260926-040300-ld/launch.png`。

Debug VM 中 `ext.chatflow.performance` 已注册，`enabled=true`，`sampleCapacity=1024`，可读 `app_startup` 与 frame build/raster 样本。首次安装冷启动 `am start -W` 为 7464 ms，应用内 `app_startup` trace 为 1631 ms；第二次进程启动 trace 为 1644 ms。登录页回前台的已运行任务 `TotalTime=36 ms`。这些值计时起止不同，不能相加或直接归因。第二次仅 7 个 build 样本，P95 为 941202 µs，且 startup trace 的 `frame_attribution_complete=false`；显示了模拟器启动首帧值得继续分析，但尚不能判定特定 widget/编码器是原因。

模拟器 Android 网络标记为 `VALIDATED`。从模拟器内使用保持证书验证的 HTTPS curl：Business API `/api/v1/health/live` 返回 200 / 0.105 s；Matrix `/_matrix/client/versions` 返回 200 / 0.097 s。这只证明该时刻基础服务可达，不能推断用户登录、短信、Matrix 已连接或视频上传成功。

## 诊断解释及隐私边界

2178 MI 6 的失败 trace 是转码开始后约 23.9 秒没有完成标记，队列约 1 ms，尚无上传或 Matrix event。2179 在每次真实转码尝试以 `Stopwatch` 记录 `normal`/`aggressive` 的毫秒数和封闭结果；Android 失败/取消仅传固定代码，Dart 不输出异常原文。失败区间可分类 `media_transcode`；这仍未查明特定 MI 6 编码器失败原因。慢帧与转码同时出现不能仅凭计数推定 Flutter 是主因。

本地 VM snapshot 才包含两档结果；上传批次的 `operations` 仍是原 schema。测试直接从 `PerformanceMetrics.snapshot()` 与 `ChatDiagnosticBatch.toJson()` 两个出口断言了此界限。记录没有消息、用户身份、Token、roomId、媒体路径/内容或 E2EE 数据。没有访问或发送用户视频。

## 剩余限制

- 雷电并行 Debug 为新包，没有登录态；未执行真实文字/视频发送，也未复现 MI 6 的特定转码输入。真实视频发送与性能归因需要用户在该 Debug 包登录后自行触发，再读取同次本地 trace；不能把本次安装/健康探测当成发送通过。
- 本改动保留两档压缩、20 MiB 压缩产物上限与失败不发送原片的既定政策。未改编码器、Matrix SDK、Outbox、E2EE 或生产接收端。
- 当前 Flutter/HTTP/Matrix 栈没有可靠的 DNS/TCP/TLS/TTFB 分段 hook，这些指标仍为 unsupported/null；媒体上传与事件发送在 SDK 中也没有可真实拆分的阶段。
