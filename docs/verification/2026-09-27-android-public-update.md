# Android 0.4.16 / 2185 正式更新

## 用户授权与交付范围

用户明确要求“推送Android版本更新，推送更新弹窗”，授权正式ARM64包、下载入口和Android更新设置。沿用已批准的账号资料/设置热缓存、好友三渠道检索/末尾两位容差、改号失焦校验、视频预览及性能/网络监控修改。启动诊断新入口仅iOS默认启用，服务端新API仍待单独批准；此次不部署API/worker、迁移或分发iOS。

阶段状态：Android **0.4.16 / 2185** 于2026-09-27 **17:39:44.552+08已正式发布**，下载包、ARM64别名与更新弹窗设置读回通过；独立发布证据复核PASS。线上预检Android0.4.7/2172、iOS0.4.7/2173；双方minimum3保持。正式2185高于既有Debug2184。源任务及线上未发现该版本/build占用，GH CLI不可用，CI任务预留未独立查询；未触发CI或Git tag。

## 最终工件与来源

- 源码commit：**b36a291139fd236e9cd0dad8e22d97d148bcefbb**，仅范围内移动增量及版本工具提交；未推送Git远端，保留继承backend/frontend工作。
- [移动1764输入](artifacts/2026-09-27/android-public-update/frozen-mobile-input.json) SHA256 **1fce8a7d750f9e3a0c741a839883096ee41a2553bcf4f8112c7166f3291ca3fc**，构建前后移动工作树干净。与此前4775全量输入仅pubspec/app_config/app_config_test三项变化。
- 版本 **0.4.16 / 2185**，包名 **com.liuhetong.mobile**，仅 **arm64-v8a**，non-debug标准release，无split偏移。
- [最终重建APK](artifacts/2026-09-27/android-public-update/build/final.apk)：**81,505,310 bytes**；SHA256 **3f7c6c48101b49b05d216b21c367ac405d1a0f54d774a2978b020f18227b0187**。
- 固定用户验证证书 **75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff**，RSA3072；本机apksigner verify通过，不向服务器传签名材料。
- [已发布的不可变APK](https://www.liuhetong888.com/downloads/ChatFlow-0.4.16-build2185-arm64.apk)。签名交接和包字段见[唯一发布记录](artifacts/2026-09-27/android-public-update/release.json)，SHA256 **575b6f62f2d1cd9bfb1183b20c7cc677303377ae7ad96004172fe71a60d79e1b**。

## 构建与验证

Flutter3.44.9/Dart3.12.2/JDK17.0.20、Apktool2.12.1、build-tools36.0.0实际版本及工具SHA留存。固定依赖锁52207159…保持。首次offline pub get受本机镜像变量影响产生三个非必要升级，未用于构建；恢复旧锁并显式pub.dev离线解析后SHA与此前一致。未引入依赖升级。

源码参数：standard ARM64 release、HTTPS Business API/Matrix/Getui均为liuhetong888.com，显式 **CHATFLOW_PERFORMANCE_METRICS=true**。常规完整Apktool解包、DEX/资源/manifest重建、zipalign-P16、固定签名、签后对齐、aapt/ABI检查与独立再解包全部执行。

| 门禁 | 实际结果 |
| --- | --- |
| 版本工具 | 原脚本不支持compiledBuildNumber及宽泛替换，真实red7FAIL及作用域red1FAIL；最终15PASS、PowerShell parse0；保留运行时initializer、拒绝歧义/异常前态 |
| 版本/更新增量 | 首轮33PASS/3FAIL（测试硬编码2184）；仅改已编译build相关期望为compiledBuildNumber，36PASS/退出0，旧四位/未知/旧三位行为保留 |
| 源码全量复用 | 4775PASS/9skip、analyze0及仓库门禁闭环输入保持；仅版本常量/测试变化以专项补充，不重复等价完整门禁 |
| 源码构建 | 首轮已知integration_test开发注册错误exit1；移除唯一dev注册块exit0，重试exit0（111.2s）；失败原日志保留 |
| 重建/签名/ABI | 后续所有必要stage退出0；最终driver退出0；25,346类/338原生库及Flutter资源内容保持，6DEX及resources.arsc实际重建，manifest语义一致 |
| 发布器 | 既有轻量publisher14PASS，无源码改动；新惰性包装器20项保护测试PASS，含禁止HEAD重定向转GET/HTTP降级和有界metadata适配；真实12FAIL→20PASS闭环 |
| 独立审查 | 先[规格/工件PASS](artifacts/2026-09-27/android-public-update/spec-review/artifact-closure.md)，后[质量/安全工件PASS](artifacts/2026-09-27/android-public-update/security-review/artifact-review.md)；[生产操作包装器复核PASS](artifacts/2026-09-27/android-public-update/security-review/operational-review.md) |

源码构建首失败及Kotlin插件未来兼容提示保留，未抑制或把失败重写通过。构建阶段完整验签/语义校验与发布阶段HEAD职责不同；发布不重复下载安装包。AndroidARM64包未安装到x86_64模拟器独立debug应用，不自动卸载或清数据；真机安装/视频/弹窗显示未验收。

## 生产操作约束

仅上传验证过的final.apk，以本地/服务端SHA和大小证明传输完整。新0700暂存 `/opt/starchat/releases/android-public-update-2185-20260927`；不可变文件不覆盖异内容。旧包保留，仅guard切latest-arm64.apk；arm32/x86_64旧别名保持。既有publisher通过公开SettingService原子更新Android版本/build/APK URL三键及审计，保留Androidnotes、双方minimum3和全部iOS设置；Androidprepare没有共享静态渲染，不覆盖旧iOS源码或网站。

重新比较十项设置、别名、静态及当前容器；不以旧快照覆盖漂移。DB结果不确定时保留已验证资源和before状态，先检查审计再恢复/重试。旧immutable包及旧设置/别名是回退依据，不删除审计。

## 阶段计时与下一步

服务器只读预检17:17:19+08；构建17:23:57–17:29:33+08，含一次开发注册修正重试，详细stage JSON保存真实起止/退出。初始完整工作起点及主动/等待分解未完整记录，不能编造精确总工时。

发布命令17:39:33.930–17:39:47.162+08（13.232s），设置审计17:39:41.111+08，发布完成17:39:44.552+08。工作站TLS17:40:29.490–17:40:31.944+08（2.454s）；持久备份/17容器证明17:41:12.085+08。阶段互不相加为虚构总耗时。

## 正式发布结果

[服务器发布报告](artifacts/2026-09-27/android-public-update/server-publish/report.md)、[实际结果](artifacts/2026-09-27/android-public-update/server-publish/publication-result.json)（SHA256 **40a1995ff2abf927815365e97e8f74d8c053189e64bda06191448027648f3028**）均为ANDROID_PUBLICATION_PASS/PUBLISH_PASS，退出0；上传与生产资源哈希/字节数匹配上述固定签名工件。

- 不可变APK上线，latest-arm64.apk指向2185；旧2172仍HEAD200，其他ABI别名仍原0.3.36，未发布这些架构。
- 十项版本设置只修改Android三键；iOS仍0.4.7/2173、双方minimum3和notes保持。共享下载页/admin-home/iOSmanifest哈希未变。现有更新流程在启动/恢复或“关于→版本更新”检查时获取新版本；未核验真机弹窗与安装，未发送无关推送通知。
- 三条settings.update SUCCESS审计：APK URL **51399a1e-39b3-4961-a129-2138e66d1e32**；build **c3295460-0427-4214-9907-638fce824c7e**；version **fa5cd76e-b102-420f-9605-d2f62ab036c8**。trace为release-metadata-android-public-update-2185-20260927T093935Z。
- 0700持久备份`/opt/starchat/docs/verification/artifacts/2026-09-27/android-public-update-2185-20260927T093935Z`保留before/result；无需回退，受限恢复步骤见发布报告。API e880ec8e、worker15659d6c、schema0090及17个生产容器身份/启动时间/重启计数保持。
- 服务器及工作站严格TLS、无重定向；APK/别名/旧包/iOS安装HEAD200、健康200、双平台匿名版本请求401。直接只读路由投影确认平台版本，不冒称已验证真实用户HTTP会话。二进制HTTP GET为0；自有临时SOCKS PID26660于17:40:31.964+08关闭。

[独立质量/安全发布证据复核](artifacts/2026-09-27/android-public-update/security-review/publication-closure.md)19项保留证据比较PASS，不新增网络或重复源码测试。五项版本/工具/test源码已漂移保护回填，见source-backfill.json；最终文档、APK与必要证据同步主目录，其余任务修改保留。

授权Android发布范围完成。真机弹窗/安装和功能反馈可继续验收；启动诊断新API候选及iOS分发仍待独立授权，旧iOS0.4.7无法上传新增启动埋点。
