# 动态表情单独发送与首帧热恢复

用户本轮三项要求完成实现、验证与模拟器debug更新。首次明确基线计时2026-10-09T08:59:54+08，调查更早开始但准确起点未知；完成2026-10-09T09:59:41.461375+08:00。继承用户授权的debug迭代，不发布官网/弹窗/CDN。

## 交付

保留数据覆盖emulator-5556 / com.liuhetong.mobile.debug **0.4.41+2210→0.4.42+2211**。firstInstallTime保持2026-09-26 04:06:20，安装后baseAPK SHA与成品相同，15秒进程稳定，Dart未处理异常/框架断言/Java/native fatal计数均0。仅存计数，无应用原始日志/消息正文。

[x64 debug APK](artifacts/2026-10-09/emoji-direct-send-warm-resume/ChatFlow-0.4.42-build2211-x64-debug.apk)：125811233bytes / 119.98MiB，SHA256 `49e3189376cab3d42c686d5007b9264d915641ae124a474726da3e65dad70bbe`，固定75b31c66…ba61fff。源码编译、Apktool2.12.1常规DEX/资源/清单重建、16KiB对齐、固定签名、独立语义和完整Flutter资产验证共26步骤exit0。未新增动态WebP到APK；56资源7643074bytes私有缓存逐项SHA读回验证。没有uninstall/clear-data，QA输入法恢复并删除本任务helper。

源留在managed worktree `C:/Users/Administrator/.codex/worktrees/android2205-sync-deadlock/StarChat`，`codex/android2205-sync-progress-20261009`，baseline b09bf2f214656c617a0171711d47f4089904e893 加既有WIP和本次改动，无Git提交/合并。冻结1935移动输入，build manifestSHA `432e999ffdb78fb06914100c374e4aec0e2bb25dbe463c0db10e6895e9a7a564`；最终gate文件集合与正常pubget后build集合完全相同，构建前后零漂移。锁始终12ae6742…771f191e；官方pub.dev enforce-lockfile exit0，无依赖升级。生成脚本/契约非mobile输入另绑send owned hashes。

## 行为与验收

| ID | 最终行为 | 证据 |
| --- | --- | --- |
| S1 | 动态tab点击独立发送一枚Unicode，保留文字草稿、选区、提及、回复；重复点击各自txid，失败/权限受既有outbox控制 | send发送RED、41PASS+4权限/重试专项 |
| S2 | 仅一枚完整catalog grapheme可作动态消息（保留外部空白trim）；多个或文字混排、输入框/旧多表情均静态；普通tab仍插入文字；custom图片/GIF不改 | 分类/inline/input/legacy渲染测试，generator同步契约1PASS |
| S3 | 已下载动画加载初帧时保留中性固定几何；默认runtime仓库未知状态不闪SVG；确定缺失/失败才静态回退 | 默认无store注入真实path_provider入口RED→GREEN及native冷打开 |
| S4 | 热帧同步借用，面板/房间复开首绘制不再先画SVG；56项面板10次复开每项帧ready | native all-renderers-ready，warmHits560/初开miss56 |
| S5 | 离屏暂停tick；idle最多64项、4MiB当前帧、8codec、30秒TTL，最多2个解码/缩放任务；LRU/后台/压力/销毁释放 | warm19PASS、native关闭不增帧、dispose全0 |
| S6 | 最终完整验证与独立SPEC→QUALITY通过 | native5PASS、Flutter5730PASS/9skip、边界377PASS/23skip、Appanalyze0、三policyPASS |
| S7 | 固定签名常规重建、保留数据覆盖、私有缓存及启动检查 | root artifact/steps/install/seed/startup receipts |

实现分两个域：room_page、panel、catalog/generator、EmojiText、输入装饰、SuperEmojiMessage修改发送和静态规则；共享pool/image/glyph/store负责播放与缓存。朋友圈评论不支持独立大动态聊天消息，隐藏动态tab、保留静态完整catalog与custom GIF，未把选择变成新的自动评论业务写入。existing Matrix通讯/outbox/E2EE、权限和业务/财务边界保留。

真实根因：旧panel共享普通插入回调；原分类允许1–4，inline也播放；pool最后订阅关闭即销毁+glyph先展示不同静态SVG；fresh runtime初始化延迟则再次先画SVG。新pool借用同资源当前帧并从有限缓存恢复，paint-only不逐帧重排。verifiedFile只查stat指纹（size/mtime/ctime/type、nofollow），不在主线程读内容算SHA；未知/变化文件异步完整SHA，20同id验证合并，140次快查不增加hash计数。

## 原生实测与限制

最终模拟器5/5：140可见/16独立资源、12快滑、10真实IME显示/隐藏、真实panel10复开全部首帧ready、默认仓库冷初始化、路由/后台/内存压力。56个面板当前帧2809856bytes（约2.68MiB），闲置decoder8，关闭不继续tick，销毁所有帧/codec/订阅/任务归零。默认冷入口首帧336ms，>30帧播放就绪615ms；不是零延迟冷解码。

644帧debug模拟器build p50/p95/p99=2.500/12.779/59.772ms、max391.985ms；raster p95/p99=2.714/6.207ms。不称真机零卡顿。4MiB是可选闲置当前图像像素，不是全App/RSS限制；活跃可见项照常播放，source codec256px scratch未按字节测量，最多8闲置+2待完成操作；高DPR字节超限/TTL/后台/压力可合法淘汰，重新进入仍需解码。文件快路依赖private不可变所有权，不能防御攻击者保留所有stat字段的恶意篡改。

## 门禁过程与时间

SPEC发现真实首次默认仓库SVG遗漏，已保存FAIL并通过startup修复重审；此前注入store的native成功不冒充覆盖此入口。新实际默认入口native通过。初始native3/4的IME show在focus/client连接前调用超时，测试加实际frame绑定，QA包注册异步等待，最终10cycles完整通过；QA enable/set初始注册错误均留档。Appanalyze最初4brace infos修复，最终0。首次freeze因文件已存在拒绝覆盖，重命名旧manifest后正常冻结，未绕过source比较。构建脚本两处复制来的旧0.4.41正则导致预检拒绝新版本；仅更正为0.4.42，保留失败，复用已完成的官方pubget和冻结输入，经完整预检后重新构建。

原32idle成功native发现56面板每次淘汰24，增加count到64而不增加4MiB/8codec；56全首帧RED→19GREEN及强化native全项首绘验证。早期全量在1:46/+1961取消以改变cap，没有声明通过。第一次完整全量5727PASS/9skip/3fail：旧单表情测试期待初始化前SVG，与新中性首帧规则冲突；另外两处未改动的SDK自愈和朋友圈图片异步测试收尾存在时序问题。保留完整失败日志，测试按真实完成信号等待，保留重试/尺寸/单次同步断言；没有修改SDK或朋友圈产品逻辑来掩盖失败。修正后的最终串行全量exit0。测试文件变更不影响已验证的原生产品输入，指纹复核后复用native5PASS。既有vendor51分析诊断复用，vendor未变；KGP迁移等既有平台提示不称warning-free。`verify.ps1`缺.env预检不启动，手动适用门禁完整执行，不导入生产秘密。原有百万历史陌生ID首次查约5秒、iOS问题与真机profile本轮未解决/验证。

阶段精确start/end/exit身份见root receipts：最终native结束2026-10-09T09:25:00.6910022+08:00，全量结束2026-10-09T01:53:11.5782578+00:00，构建结束2026-10-09T01:57:37.8246962+00:00，安装结束2026-10-09T01:58:43.957709+00:00。初期调查起点未知，未编造主动工时或相加并行耗时。实际正式Android2206/iOS2205/官网候选2209/弹窗保持，资源和差分API未公开部署。

下一步：用户检查模拟器emoji直发、文字草稿/多emoji静态、面板/房间复开体验；手机可连接时做Android release/profile，不自动公开发布。
