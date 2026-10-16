# 超级表情自动播放修复与资源评估

当前源码候选：544b61b63f30273d3fd2e198d11bd809a8fd0090，0.4.47+2216 的 autoplay 修订。最新要求覆盖此前“默认静态，点击播放”。正式渠道未由本任务修改。构建、设备及 iOS 结果在本文末尾追加，不用旧包冒充修复包。

## 根因与修复

消息行 `SuperEmojiMessage` 显式传入 `playOnTap:true`，使 `EmojiResourceGlyph` 在用户点击前不进入动画资源解析/订阅路径。这是上一轮体验改动造成的行为回归；现有证据不支持“因OOM自动停止”的判断。

已移除消息行的手动模式，复用默认可见自动播放。SVG/Unicode 即时预览保留；图片加载或解码未完成时不会改为空白。相同资源和尺寸共享解码，离屏停止推进，短时返回复用当前帧，后台释放，前台恢复。显式点击模式 API 仍保留供需要它的调用方使用。未修改消息协议、E2EE、账户隔离、数据库或发送状态。

## 内存与取舍

建议保留动态表情。删除功能或全局改为手动播放会改变已经明确的产品体验；先按实际可见性和资源预算控制成本。

| 项目 | 已核实事实 | 解释/限制 |
| --- | --- | --- |
| 源资源 | 56个WebP，合计7,643,074 bytes，均256×256；49个多帧、7个单帧 | 单帧资源本身不会动画，不适合作播放验收样本；压缩文件大小不是解码内存 |
| 当前帧 | 按显示尺寸分档，最大256px；每个独立解码键最多保留当前帧 | 256×256 RGBA约256KiB；同资源同尺寸多个实例共享。不能当成完整codec/GPU内存上限 |
| 并发 | 启动与后续解码共用队列，并发上限2 | 限制突发工作；可见独立资源总数并无硬上限 |
| 离屏缓存 | 最多64项、当前帧合计4MiB、最多8个闲置codec、TTL30秒 | 4MiB只限制闲置帧，不限制活跃codec/native临时缓冲和整个进程 |
| 后台/压力 | 清理帧与codec；压力后经队列恢复可见资源 | 主机假codec专项验证生命周期，真实设备结果另列 |
| 磁盘 | EmojiResourceStore默认64MiB配额，校验后入缓存 | 此次不改资源格式、缓存清理或下载策略 |

后续有明确收益的优化路径：P1在低内存Android和iPhone用Profile/Release记录同场景PSS/native、帧时间、连续切房20轮；P2增加128/192px资源版本，避免平台解码器按原尺寸分配临时缓冲；P2在实测证明需要时，对大量不同可见表情降低帧率/引入压力期间静态降级，恢复后自动播放，不重新要求点击。资源变体需保留校验清单、静态预览与灰度回退。是否节省内存、节省比例及功耗均须A/B实测，本文不预报收益百分比。

## 验证记录

所有日志位于 [独立证据目录](artifacts/2026-10-16/super-emoji-autoplay/)，未覆盖前次2216结果。

- RED：主机首次因过期短盘符V不存在而启动失败（环境错误，非行为RED）；恢复已验证短盘符后，无点击资源请求预期1、实际0，7项中1失败；HTML预期playing、实际static，4项中1失败。
- GREEN：60项相关Flutter测试PASS，覆盖无点击资源加载、静态fallback、帧推进、共享同一资源、离屏停止、返回/后台恢复、缓存和手势。完整Flutter analyze退出0。SVG parser已有filter诊断保留，不宣称测试日志零警告。
- 最终候选共享全量：6038 PASS / 9 SKIP / 0 FAIL，退出0，09:01:27–09:17:36+08。使用已核验Olm3.2.15、SQLCipher4.10/SQLite3.50.4和独占短V路径，依赖锁SHA a43833c8…ecc5d；这是本次真实完整结果，不覆盖前次失败日志。
- UI契约34组件/540页面PASS；专属HTML4项PASS。浏览器验证初始自动、离屏暂停、返回自动、后台暂停与返回自动。Demo URL：`http://127.0.0.1:4173/?screen=chat-experience-static-emoji`（本地服务运行时可访问）；画面为合成演示，不能代替设备性能。
- 前端全量562 PASS/5 FAIL：与上一轮相同的旧下载版本断言，相关7个输入Git blob逐项一致，记录于frontend-baseline-reuse.json。此次没有改发布页来掩盖历史失败。
- Python移动边界377 PASS/23 SKIP，退出0；跳过的原生/环境项目不是通过。
- `scripts/verify.ps1`前置`.env`仍缺失，复用前次相同脚本与配置门禁的阻断事实，不借用生产密钥；不宣称全仓verify通过。
- 独立SPEC PASS→QUALITY APPROVED；非阻断建议为新测试应在断言前注册失败路径清理。未发现新增生产资源安全缺陷。

![合成HTML演示：可见自动播放](artifacts/2026-10-16/super-emoji-autoplay/html-autoplay.png)

## 回退与未覆盖

源码回退本次消息行/HTML改动可恢复手动播放，无迁移。设备回退使用已保留、同签名的旧main Debug并执行install-r，不卸载/清数据。公开2215与候选2216分开，不能把模拟器Debug帧统计当真机Release性能或无OOM承诺。iOS旧unsigned IPA不包含本次修复；新CI run38833391106从544b61b6构建，最终签名和真机播放仍是独立验收。

## 新iOS成品

run38833391106/device job116756980946 SUCCESS；Windows下载后验证退出0：完整arm64、29插件/46框架、ZIP CRC/逐框架SHA、版本/权限/后台模式与未签名状态通过。新IPA **34,980,861 bytes，SHA256 df32ef4f3d41332de7541bb75ea12accee3d5eb9bbfe4d064f6130d0a054bd6d**。

已复制并校验 [新未签名IPA](C:/Users/Administrator/Downloads/ChatFlow-0.4.47-build2216-autoplay-544b61b6-unsigned.ipa)。它属于未发布2216候选的autoplay修订，文件名带源码身份区分旧2216，不代表已签名或已公开发布。继续沿用用户确认的生产APNs身份要求；真实iOS动画、后台通知及覆盖升级需匹配签名真机验证。

同一工作流的存储模拟器job已主动取消（最终run cancelled，device job仍为success）：设备包完成后，逐项确认iOS原生、core/features、锁文件、5个原生存储目标与工作流相对79e08436完全相同，按工作流规则停止重复门禁。复用原21PASS/2保护目录ERROR及独立4PASS/4capabilitySKIP；这两个历史错误没有被取消动作关闭，也不把本次native job写成通过。复用依据为ios-native-reuse.json。

## Android成品与真实播放验收

09:17:40–09:23:17+08 完成源码→Apktool2.12.1常规重建→对齐→固定75b31签名→语义/资产核对。最终 [x86_64 Debug APK](artifacts/2026-10-16/super-emoji-autoplay/android-main-autoplay/final.apk) 为125,933,914 bytes，SHA256 **21553235a4ec7ef7e68a8d780dae43dac583f74ea3a31ff80c466ec6328ceab5**。

09:23:46–09:23:58+08 install-r完成，模拟器5556/API28/Android9/LDPlayer9，UID10090、首次安装时间2026-09-26 04:06:20保持；实际安装APK完整SHA一致。未卸载、清数据或热重载。新候选保留原账号/房间；末态为实际main应用。

用既有、仅自己一人的加密测试房间，通过公开controller发送3条已知Unicode样本（两条相同、一条不同），无其他接收者。旧包先实测、随后覆盖新包复测同一批已同步消息。VM只读取脱敏诊断计数；没有点击表情或注入播放/生命周期状态。后台、返回及滚动使用实际Android操作。

| 场景 | 观测结果 |
| --- | --- |
| 旧包可见、不点击 | 2秒推进0帧，0订阅；确认设备旧APK SHA ae7e9eab…619 |
| 新包可见、不点击 | 2秒合计推进40帧，两个资源分别17/23帧；3订阅共享2实例 |
| 实际Home进入后台 | 2秒推进0帧；活跃/闲置帧占用均0 |
| 实际恢复前台 | 无需点击，2秒推进50帧 |
| 滚出可见区域 | 2秒推进0帧，活跃0，闲置当前帧暂留0.5MiB |
| 滚回最新消息 | 自动推进50帧/2秒，warmHits增加2，没有新建codec |
| 退出房间、再次进入 | 导航过渡的第一段2秒采样尚无活跃实例；稳定后自动推进51帧/2秒，warmHits2。不能宣称瞬时恢复或首帧P95达标 |

稳定时2个256px当前帧合计524,288 bytes（0.5MiB）、解码峰值并发2。上述帧数是两个资源的累计推进，不是UI FPS。新进程点采样PSS约337–368MiB，native PSS约46–53MiB；其中包括Flutter Debug VM、SDK、页面与已有媒体，不能把总数归给表情。旧包PSS点采样约387MiB，运行时机/GC/JIT不同，**不据此宣称内存降低了某个比例**。受限日志采样OOM/FATAL/Unhandled计数均0，未做长期泄漏/低端真机压力结论。

机器断言汇总：[runtime-acceptance.json](artifacts/2026-10-16/super-emoji-autoplay/runtime-acceptance.json)。

![实际Android候选自动播放页面（单张截图只显示一帧，推进证据见JSON）](artifacts/2026-10-16/super-emoji-autoplay/new-autoplay.png)

交付结论：P1手动点击回归已修复并在Android实际main验收；建议保留动态表情，保留现有共享/可见性/后台资源控制。P1补充低内存Android与签名iPhone Profile/Release验证；P2再按测量结果引入较小源资源、减少动画选项或内存压力降级。正式APK/IPA下载渠道和更新弹窗没有由本任务改变。

09:32+08 独立交付证据审查PASS。临时Flutter attach已正常detach，独占V/W映射与本次两个SDK forward已移除，既有54358 forward保留；本次VM会话缓存已删除，未保存凭据。HTML临时服务与标签页已关闭，截图/源码保留；采用现行ui-demo-delivery，Figma同步已退役。本次总墙钟约41分钟，包含969秒共享全量、337秒重建/语义校验；iOS与本地并行，不把阶段时长简单相加。
