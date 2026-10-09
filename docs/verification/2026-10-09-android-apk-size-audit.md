# Android 安装包体积审计（2026-10-09）

用户询问79.2MB构成、增长与冗余，以及后台下载资源和避免全量更新的可行性。本次只读审计本地最终交付APK，未修改产品、重建或发布安装包。

## 输入与方法

- 候选0.4.38+2207：83,110,942 bytes = 79.26077 MiB；SHA256 `ad8cc9d8826130449e21eb094b42728349bcf0590f021b71ac82e8c03fe0e324`。
- 正式0.4.37+2206：82,848,798 bytes = 79.01077 MiB；SHA256 `fb7005f59c0a8e7a16a633a06f5cca10d30784c4508912cb442d95cefbd02436`。
- [脚本](artifacts/2026-10-09/android-apk-size/audit_apk_size.py)、[逐文件统计及SHA](artifacts/2026-10-09/android-apk-size/apk-size-audit.json)、[实际输出](artifacts/2026-10-09/android-apk-size/audit.log)。ZIP compressed size表示下载包内占用；解压大小另列，不能混加。校验已知最终包SHA、每条目SHA及总和一致性，执行exit0。
- 实际源代码核对：`C:/Users/Administrator/.codex/worktrees/android2205-sync-deadlock/StarChat`，候选版本metadata commit c1883df7。主工作区旧pubspec版本不作为候选依据。

## 下载体积构成

| 类别 | bytes | MiB |
| --- | ---: | ---: |
| 14个ARM64原生库 | 56,624,488 | 54.00 |
| 6个Android DEX | 10,388,130 | 9.91 |
| Flutter图片、表情、字体等资源 | 13,490,359 | 12.87 |
| Android资源、其他文件与ZIP/签名/对齐开销 | 2,607,965 | 2.49 |
| 合计 | 83,110,942 | 79.26 |

原生库主要为libapp.so 18,809,744 bytes、libflutter.so 11,581,856、WebRTC libjingle_peerconnection_so.so 11,377,944、SQLCipher 5,187,544、扫码libbarhopper_v3.so 4,946,720、libcrypto.so 2,594,184。包中仅arm64-v8a，没有多ABI重复。原生库采用ZIP stored；不能未经平台加载、签名与对齐验证直接压缩或移出APK。

2207比2206增加262,144 bytes（0.25 MiB），930条目中924个内容完全一致。变化仅Manifest、classes5.dex、libapp.so和3个签名文件；所有319个Flutter资源条目完全相同。该次增长主要是应用编译代码，不能推断更早各版本增长原因。安装包不包含用户聊天数据库和媒体缓存；APK大小也不等于运行时全部驻留内存，不能直接解释历史消息卡顿。

## 可优化内容与边界

| 内容 | 当前包内体积 | 核对结果及方向 |
| --- | ---: | --- |
| 56个动态WebP大表情 | 7.29 MiB | 表情面板与消息气泡实际使用；适合独立版本资源包，不能直接删除 |
| 225个静态SVG表情 | 0.59 MiB | 实际使用，可作为基础离线资源；与动态表情用途不同 |
| app_icon~1.png、app_icon~2.png、LOGO.png | 1.21 MiB | 未发现运行时Dart引用，目录整体声明导致打包；待完整用途核对后排除 |
| diagnostics测试音视频及README | 0.71 MiB | 精确路径核对只发现integration_test及test引用；正式构建可考虑排除，保留测试专用声明 |
| app_icon.png | 0.55 MiB | 启动图标生成源；不能删构建源，是否需要作为Flutter运行资源另行核对 |
| landing.png | 0.97 MiB | 登录背景实际使用；可以评估图片压缩，不能直接移除 |
| MaterialIcons字体 | 0.53 MiB压缩体积 | 当前保留完整图标以避免既往缺图标故障；不能盲目裁剪或仅依赖网络 |

候选pubspec声明整个branding和diagnostics文件夹；诊断媒体源仍应保留供测试使用。品牌备份未引用的结论来自精确源码搜索，非完整动态运行覆盖证明。Java/Android构建目前未开启R8压缩，与既有不请求R8混淆的交付边界一致，本次不更改。

## 两种不同改进

1. 资源后台下载：把动态表情发布为CloudFront资源包，版本和SHA校验、断点续传、缓存复用、低优先级/Wi-Fi预取、失败回退基础表情。离线首次进入、聊天登录、输入及消息排序不能依赖下载完成；系统调度意味着后台任务不能保证即时执行。现有Image.asset调用需改为支持本地缓存的公共加载接口，不能仅改pubspec。
2. 差分安装包更新：对明确旧APK SHA制作补丁，在本机重建完整新APK并校验完整SHA及签名，再走系统安装；基线不匹配或补丁失败回退全包。924条目相同说明值得测量，但0.25MiB增长不代表补丁只有0.25MiB，尚未制作或测量补丁。当前app_update.dart使用externalApplication打开下载URL，没有差分更新实现。

Flutter引擎、应用编译代码、加密与通话核心库应随受验证的安装包交付。动态资源下载减少基础包与重复资源流量；差分传输减少代码升级流量，安装后的完整APK仍存在。扫码模型另有官方非捆绑模式，但依赖Google Play Services及模型首次下载，不能直接用于所有国内设备。

依据：[Flutter包体积分析](https://docs.flutter.dev/perf/app-size)、[Android包体积指南](https://developer.android.com/topic/performance/reduce-apk-size)、[Android后台任务](https://developer.android.com/develop/background-work/background-tasks)、[PackageInstaller](https://developer.android.com/reference/android/content/pm/PackageInstaller)、[ML Kit扫码安装选项](https://developers.google.com/ml-kit/vision/barcode-scanning/android)。

## 结论及未执行项

调查完成，可优先排除已确认测试资源、核对品牌备份，再实施动态表情资源包；差分更新需要独立设计及真实补丁大小/覆盖升级验证。不承诺未经重建测量的最终缩包值。本次没有Flutter函数级analyze-size、签名重建、新手机性能测试或生产变更；只读包分析无需重复此前发布构建门禁。

后续用户授权实施后另做本地差分选型实验，测得2206→2207 payload复制补丁10.56MiB并精确还原最终SHA；见[新任务](../workflow/tasks/2026-10-09-mobile-responsive-maintenance.md)。这是后续证据，前述“未测量”描述保留原审计时态；尚未实现手机更新。
