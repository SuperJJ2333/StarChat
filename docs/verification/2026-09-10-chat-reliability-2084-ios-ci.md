# iOS CI 与原生兼容性验收增强

## 现象与边界

用户原始设备描述保留为 iPhone 15、iOS 26.6。当前开发环境是 Windows，没有 macOS/Xcode，未执行原生编译、模拟器运行、签名 IPA 生成或实机验收。CI 现有矩阵是 iOS 18 / 26 的可用 runtime，必须以产物 selected.json 中的实际版本为准，不能把 major 26 写成已验证 26.6。

旧兼容性任务因 MLKit 缺失 arm64 模拟器 slice 而临时排除 mobile_scanner，不能证明完整生产插件组合能编译。视频验收此前只解码既有媒体，没有执行新增 AVAssetReader/AVAssetWriter 编码路径；存储验收此前只覆盖 legacy key。

## 修改

- `.github/workflows/ios-compatibility.yml` 增加独立 `production-compile`：Xcode 26.3、Flutter 3.44.9，以完整原始 pubspec 对默认 main 入口执行 `flutter build ios --release --no-codesign`。没有扫描插件排除、没有签名 secret 依赖。上传 toolchain 和 production-compile.log。原模拟器局部排除仍明确记录在 limitations.txt。
- `.github/workflows/ios-0353.yml` 增加 `workflow_dispatch`，手动运行仅允许 main；原推送入口保留。已有签名、IPA 内容/签名验证、原生 call/Keychain Swift core tests 保留；App Store Connect 上传仍为 `if: false`，未开启发布。
- `ios_compatibility_test.dart` 使用现有 `generate_ios_compatibility_fixtures.py` 生成的四秒纯合成 H.264 / HEVC 片段，各执行 normal / aggressive 参数直接调用真实 VideoCompress 插件（四个编码测试）。显式 maxDimension/videoBitrate 将进入新增 ChatVideoEncoder 的 AVAssetReader/Writer 分支。检查产生不同输出文件、保留源、输出非空且 ≤20 MiB、时长约四秒、尺寸上限、原生解码并推进。正常档小于上限时生产管线不会自动尝试第二档，因此这里直接调用相同配置确保两档都实际执行。
- 语音原生测试增加暂停后实际继续推进、播放中切换听筒/扬声器、停止后重复播放，并通过 engine.dispose 清理其临时文件。
- 存储测试增加 A→B→A，两个账号 key 不同、切回同一 key；新进程先只读 native key、active pointer、registry 和非敏感摘要 marker，证明保留后再调用可能创建 key 的 getter。仅纯合成账号/会话，没有网络上传或真实密钥日志。原 legacy SQLCipher 跨进程检查仍保留。
- 未修改 RunnerTests.swift、Info.plist、project.pbxproj、依赖或 Pod lock。

## 本地红绿与验收

证据目录：`artifacts/2026-09-10/chat-reliability-2084/voice/`。

- ci-red.log：三个新增配置/验收覆盖断言分别因完整编译任务、dispatch、编码验收缺失失败；旧两个断言通过。
- ci-green.log：同文件五个断言全部通过。当前 Python 无 pytest，直接用 runpy 调用纯断言测试函数，没有安装依赖。
- ci-yaml.log：Dart 项目现有 YAML parser 对两个 workflow 成功解析，分别两 job / 一 job。
- ci-analyze.log：harness Flutter analyze 无问题。
- ci-focused.log：voice source/controller、iOS secure session、video send limit 共 43 项通过。
- 以上不构成 iOS 原生执行成功证据。仓库总 verify.ps1 由 root 统一执行。

## CI 触发所需信息与后续检查

需要目标 GitHub 仓库 owner/repo、包含这些改动的 main commit，以及有 Actions 触发权限的已登录身份。workflow_dispatch 文件需存在于默认分支，签名任务的 ref 选择 main。可在 Actions 页面选择对应任务运行，或由获授权操作者使用 `gh workflow run ios-compatibility.yml --ref main -R OWNER/REPO` 与 `gh workflow run ios-0353.yml --ref main -R OWNER/REPO`。本次未触发远程 CI。

签名任务需要既有 secrets：IOS_CERTIFICATE_BASE64、IOS_CERTIFICATE_PASSWORD、IOS_PROFILE_BASE64。既有配置要求 team HY9Q7Q35S5、profile ChatFlow_AppStore、bundle com.liuhetong.liuhetongMobile、production APNs。不需要为了本次生成 IPA 提供 App Store 上传 secrets，上传步骤禁用。

完成后检查：完整生产编译 job 成功；iOS 两矩阵 seed 和 verify 均成功；selected.json 的实际系统版本与限制；ChatFlow-iOS-signed IPA 和 ios-preflight-diagnostics。模拟器无法证明真实听筒/扬声器听感、蓝牙路线、用户账号加密媒体及 iPhone 15 上的实际表现；这些仍需安装签名包实机验收。当前合成视频源为 320×240，因此该测试验证参数路径与输出上限，不证明高分辨率缩放、HDR 色彩或音频听感质量。
