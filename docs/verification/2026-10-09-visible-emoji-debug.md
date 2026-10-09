# 可见动态表情优化与模拟器 debug 交付

用户授权：优化所有可见表情持续播放，并推送模拟器 debug。开始2026-10-09T08:20:50+08:00，完成2026-10-09T08:52:17.310842+08:00。
实际已保留数据覆盖安装 emulator-5556 / com.liuhetong.mobile.debug：0.4.39+2208 → **0.4.41+2210**。固定证书75b31c66…ba61fff；安装后APK SHA与成品相同，firstInstallTime保留，启动15秒进程稳定、当前进程无Java/native fatal。官网、更新弹窗与服务器资源集未发布。

## 成品与输入身份

- [安装包](artifacts/2026-10-09/visible-emoji-debug/ChatFlow-0.4.41-build2210-x64-debug.apk)：125811233字节（119.98MiB），SHA256 `13ba41de3f4aa6a9703980374c2629ac6764cf35dd9ce1beda5c3214df844574`。
- 常规源码编译→Apktool2.12.1 DEX/资源/清单重建→16KiB对齐→既有固定签名；26项构建检查exit0，独立解包、语义、完整Flutter资源、签名/版本/ABI/锁屏边界通过。原始Flutter APK仅中间产物。
- Worktree `C:/Users/Administrator/.codex/worktrees/android2205-sync-deadlock/StarChat` / `codex/android2205-sync-progress-20261009`；baseline `b09bf2f214656c617a0171711d47f4089904e893` 加已有WIP和本次有界改动，无合并/提交。
- 冻结1933移动源输入，manifestSHA `561d6f5fdb017d7f010341c603bbd01c1b1d25dbc316a01ed0bf5e3f89ddac37`，最终门禁→正常pubget后源文件集合完全相同；构建前后零漂移。
- 依赖锁最终与任务起点完全相同：12ae6742…771f191e。过程中测试自动pub改了镜像与若干补丁版本，已保留差异并精确恢复原锁；官方pub.dev两次enforce-lockfile exit0，无依赖升级。

## 实现与验收

| ID | 结果 | 证据 |
| --- | --- | --- |
| E1 | 所有已下载可见表情播放，取消4个播放限制；滚动、输入、维护门禁期间仍播放 | native-report.json / finalspec.md |
| E2 | 资源路径+尺寸共享播放器，140可见订阅只用16播放器 | native-report.json / 7单测 |
| E3 | 离屏、离房间、后台停止；最后订阅释放codec/帧，延迟解码正确回收；内存压力释放后有界恢复 | 原生3/3与生命周期RED/GREEN |
| E4 | 96物理像素当前帧、paint-only，无每帧列表layout；最多2个解码/缩放任务 | physical-size RED/GREEN、原生实际帧数据 |
| E5 | 原SHA/大小/头部校验、Unicode、离线回退、固定几何保留 | 单测/全量门禁/双审 |
| E6 | 真实WebP16种/140可见、12快滑、10真实IME循环、路由/生命周期/压力/退出 | native-physical-final.log exit0 |
| E7 | 重建固定签名debug、保留数据安装、56私有缓存资源验证、启动 | artifact.json / install-receipt.json / seed-resources-receipt.json |

源：新增shared_emoji_player.dart、shared_emoji_image.dart，更新emoji_resource_glyph.dart，新增7单测与原生integration harness；本次版本0.4.41+2210。SharedEmojiImage固定尺寸+RepaintBoundary+CustomPainter repaint监听，动画不驱动逐帧widget重建/布局。离屏可见性仍复用现有MediaVisibility，未统一探测器。

原生发现Android动画WebP请求96px仍返回256px，修正为超限帧在有界队列中缩放再保留，完整释放原image/picture；16资源当前帧从4MiB变589824bytes（0.5625MiB），退出当前帧/订阅/解码均0。这只计当前帧像素，不含codec内部缓冲、GPU或进程总内存，源解码CPU仍可能按256px处理。

## 验证、阶段时间与限制

- 7针对单测RED→GREEN；全量Flutter **5717PASS/9skip**，Appanalyze **0问题**；边界 **376PASS/23skip**，Repository/Deployment/Template policies exit0。
- 最终原生3/3 exit0，08:41:28+08结束；全量Flutter结束2026-10-09T00:48:03.1979855+00:00；重建结束2026-10-09T00:51:04.5203748+00:00；安装结束2026-10-09T00:51:43.348729+00:00。每阶段start/end详见root receipts。
- SPEC→QUALITY/SECURITY均PASS，报告绑定最终源SHA与原生证据。打包/安装成品证据由独立质量审查复核PASS，见[交付补充审查](artifacts/2026-10-09/visible-emoji-debug/reviews/delivery-quality.md)。启动后Dart未处理异常、框架异常/失败断言、Java/native fatal计数均0，仅保存计数，无原始应用日志。
- 首次全量因lint整改取消；第二次为原生尺寸修正/恢复锁取消，期间call_alerts真实时间测试在并发编译时一次Expected4/Actual3；最终串行全量同测试通过。原生初次测试paused后pump无vsync已取消，后一次非法paused→resumed测试链失败，最终使用合法生命周期链3/3。构建preflight一次run-id格式错误已在实际编译前纠正。失败/取消日志未删。
- `verify.ps1`因缺少.env预检未启动；不引入生产秘密。未变vendor复用已说明的51项既有分析诊断，不称vendor清洁。既有插件KGP迁移提示、SVG fallback filter不支持提示有来源记录，不称无warning。
- 530帧debug模拟器：build p50/p95/p99=3.269/14.493/25.454ms，raster=1.642/5.807/21.855ms；max分别499.175/190.386ms。不能据此声称真机release/profile零卡顿。测试结束后的dumpsys memory无进程，不能推断RSS/OOM。
- 原有百万历史首次陌生ID约5秒问题仍独立缺口，2209静态回退更流畅不是证明表情是全部卡顿唯一根因。相同FileImage原本也可能共享ImageStream，不将旧实现描述成必然重复解码。
- QA键盘已恢复原拼音IME并移除本任务QA helper；未清理用户数据，未发送真实聊天消息。56个WebP总7643074bytes只注入私有缓存，APK不嵌入资源，未向CDN上传。

下步：用户模拟器体验反馈；手机可连接时做真实Android release/profile和密集不同资源场景测试，再决定公开候选发布。
