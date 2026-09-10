# 2084 视频统一自动压缩验证

范围：按已授权计划 `docs/superpowers/plans/2026-09-10-chat-reliability-2084.md`，修改 Android/iOS Flutter 视频选择、预处理、发送入口及本地插件。未构建、未部署、未发送真实用户消息。

## 问题现象

旧相册群聊会在压缩前拒绝原片超过20MiB；原图开关可选择不同视频发送路径；相机录像返回后要求再次点击发送。压缩仅比较原片减量比例，没有统一实际20MiB上限，失败/被替代产物缺少明确回收。

## 复现步骤与红灯证据

1. 创建100MiB稀疏本地测试原片，模拟普通编码输出25MiB。旧算法因为已经减少75%而不重试，返回超限文件。`video/red.log` 中期望2次实际1次。
2. 两个输出均超过20MiB，旧路径仍返回VideoRendition，没有拒绝。相同日志第二项失败。
3. 相册原片100MiB、压缩payload10字节、原图开关开启且群聊：旧prepareGalleryMedia提前抛原片超限。`video/gallery-red.log`记录失败。

以上均为本地合成文件与平台通道替身，不表示执行了真实视频编码。

## 根因排查

- CodeGraph首先定位video_transcode、相册、媒体服务和room_page调用路径。
- 原策略以50%减量决策，而不是最终20MiB；原片更大时容易放行超限产物。
- video_compress 3.1.4 Android的480p/LowQuality分支忽略frameRate参数，单改Dart帧率无效；iOS AVAssetExportSession预设没有公开音视频码率入口。
- Android原输出文件名精确到秒，相同原片快速两轮有覆盖风险。
- RoomTimelineController._dispatch会捕获发送错误并保留重试闭包；如果直接删录像源文件，重试会引用失效路径。

## 修改结果

| 条目 | 实现 |
| --- | --- |
| 统一入口 | 相册/相机/视频文件共用transcodeForChat，视频忽略原图开关，无压缩确认弹窗 |
| 普通编码 | 最长边640、H.264 1.2Mbps、24fps、单声道AAC64kbps/44.1kHz |
| 激进编码 | 最长边320、H.264160–400kbps（按时长预算）、12fps、单声道AAC32kbps/22.05kHz |
| 通过条件 | 普通实际≤20MiB即通过；超限或失败自动激进；激进仍超限明确提示裁剪，编码失败拒绝原片绕过 |
| 提前估算 | 仅原片超限且有效时长超过最低可接受音视频码率预算时提前拒绝；未知时长继续实际编码；估算永远不替代最终文件长度 |
| 双端参数 | 仓内3.1.4插件扩展Dart通道；Android Transcoder明确设置参数；iOS AVAssetReader/Writer控制H.264/AAC与帧率/旋转 |
| 清理 | 原生删除失败/取消输出，Dart删除未采用输出；预览/发送独立拥有产物并释放；相册原件不删 |
| 相机重试 | prepareCapturedChatVideo先产生验证后bytes/poster，删除APP录像原片及压缩文件，再建立timeline发送闭包；网络失败仍可从bytes重试 |
| E2EE | 仍只调用原sendEncryptedMedia，压缩在设备执行，未改变密钥或加密域边界 |

插件保留MIT许可；版本及改动说明：`apps/mobile_flutter/third_party/video_compress/CHANGES_STARCHAT.md`。`video/vendor-differences.json`列出相对本机原解析3.1.4缓存的6个新增/修改文件及SHA-256。不是官方发行包哈希认证。

## 验收证据

临时证据目录为 `docs/verification/artifacts/2026-09-10/chat-reliability-2084/video/`。

- `focused.log`：7个测试文件共67项通过，覆盖真实Dart决策及通道参数、20MiB边界、两轮失败、长片预估、未知时长、清理、相册选择UI和相机网络失败重试。
- `analyze.log`：9个修改目标无问题，包含room_page和新预处理模块。
- `android-native-api.txt`：本地Transcoder0.10.5 javap证明bitRate/frameRate/sampleRate/channels API存在；同时检查atMost单参数只限制短边，最终使用双边界参数与iOS最长边对齐。
- `pub-get.log`：offline解析仅将video_compress3.1.4从hosted改为仓内path，无新增编码依赖。
- Apple官方[markAsFinished](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/markasfinished())和[requestMediaDataWhenReady](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/requestmediadatawhenready(on:using:))核实串行队列结束输入的API。取消/失败使用正确Writer结束路径与弱引用回调。

规格自审：统一入口、真实两档参数、实际上限、提前估算、无确认、明确错误、相册原件保护与相机重试均有对应实现。

质量/安全自审：未调用deleteAllCache，未批量删除未知文件；编码串行，输出UUID避免覆盖；未加明文网络接口或服务端压缩；记录只含合成媒体。总仓库verify.ps1及跨模块审查由root统一执行，本报告不代替其结果。

## 双端实机边界

本子任务未执行Android原生编译/编码，也未执行Xcode/iOS编译或iPhone验收。Dart测试和API核查不能证明硬件编码器、HEVC、旋转、HDR到SDR、音画同步、后台中断或实际码率效果。新iOS Reader/Writer路径必须完成Xcode编译与设备测试后才能宣称双端运行验收。

发布前两端分别验证：短片普通通过、普通超限激进通过、两轮仍超限、明显长片提前拒绝、无时长/不可解码格式、横竖屏/有声无声/HEVC、压缩中离开、上传失败重试、磁盘产物回收。用户原始设备描述为iPhone15/iOS26.6，保留该信息但未伪称已测试该设备。
