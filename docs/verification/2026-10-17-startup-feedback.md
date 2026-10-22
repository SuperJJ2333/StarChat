# 2220 冷启动反馈修复验收

状态：最终产品 `45355d5f` 的普通 **0.4.52+2221 Debug** 已固定签名、保数据安装到 emulator-5556。原生五场景、真实缓存命中冷启动、头像交接和暖入房滚动验收通过。无正式发布、无真实收件人消息发送。

## 原因与修复

| 用户反馈 | 实际原因 | 最终改动 |
| --- | --- | --- |
| 冷启动群头像变成默认头像 | 投影没有群成员头像信息，空头像变为空 URI，本地 MXC 解析依赖未恢复 SDK；交接还会重建行并清掉已绘制图片 | 有界成员元数据进入既有账号隔离加密投影，只读既有头像磁盘缓存；同 owner/identity/URI 保留已绘制图片与会话行，变更、删除、撤销立即失效 |
| 错误网络不可用提示 | 缓存展示期间 loading 被映射成 offline | 仅真正 offlineAuthenticated 显示离线状态，不改变发送权限 |
| 停留消息列表多久，入房仍加载 | 完整 SDK 恢复后仍在推入房间页面之后才查询本地 timeline；列表后台恢复不等于该房间首屏已准备 | 推入页面前准备真实本地消息头及隐藏过滤，一次交接给同一 timeline，首帧直接显示气泡，准备期间原页面仍可操作 |
| 验收新增：取消入房后重入被吞 | 列表和协调器两层去重把新点击并入尚在清理的旧请求 | 统一协调器去重；取消仅退休未注册 attempt，token 隔离迟到 push/error/finally；保留 active、anchor 和完整 lease 清理 |

非根来源页返回、切 tab、关联准备期间换账号均使旧意图失效。旧任务不得清理新房间的统计上下文；正常 pop 与 AppHome dispose 使用本页面持有的幂等清理。加密、账号权限及持久待发边界保持。

证据根目录：[startup-local-projection/artifacts](C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat/docs/verification/artifacts/2026-10-17/startup-local-projection/)。私人账号截图、录像只本地保存，不在本文转录消息或账号标识。

## 源码与主机验证

- 房间/网络 `e0a09bfa`：真实数据库等待 RED→GREEN，38 PASS，独立审查通过。
- 头像 `3f2afbf4`，预算修正 `4a1ae278`：60 PASS，真实 writer 13 PASS。审查发现超限成员使整个房间遗漏，已改为仅省略超限成员。
- 头像交接 `7ada9f1d`：真实已绘制 FileImage→等待 full provider 及真实 main 行销毁 RED→GREEN；56 项未变覆盖复用＋最终入口 5 PASS。两次 60 PASS/1 FAIL 保留，固定 IO 等待改为有界实际就绪/绘制条件。独立审查通过。
- 原生回调夹具 `f343f770`：逐帧回调改同步 finder 读取，SQL barrier 每次独立 entered 信号；5 PASS/52秒，独立审查通过。产品未变。
- 最终取消重入 `45355d5f`：真实 SQL held 取消/返回重入、关联准备后旧意图继续读取、旧 cleanup 清新统计上下文、dispose 遗漏均有 RED。最终 AppHome 10＋真实 main 5＝15 PASS，复用未变 coordinator 22/list 3/RoomPage 16＝41 PASS；原组合 55 PASS/1 FAIL 如实保留，旧 revoke 测试固定等待改为有界实际清理条件，生产 revoke 未变。最终独立审查 `feedback-native-r3-review.md` PASS，7 项源码/lock hash 核对通过，完整 analyze 0 issues/12秒。

完整 Flutter 命令在 `4a1ae278` 得到 **6134 PASS / 9 SKIP / 2 FAIL，exit1，24分3.608秒**。两项旧夹具修正后 29 PASS；按变更影响复用未变化覆盖并运行上述专项，不能把原始全量命令记作 exit0。移动端边界 377 PASS/23 SKIP，UI 契约 34 组件/540 页面 PASS，元数据 3 PASS，仓库策略 PASS。完整 verify.ps1 环境预检缺 `.env`，未导入生产秘密，故未运行其完整聚合门禁。iOS 未构建或设备验收。

## 设备反例与已有证据

- `user-feedback-2220`：普通已恢复入房视频显示加载文字→气泡，确认用户反馈；真实数据库 RED 覆盖该分支。
- `feedback-cold-baseline-2220`：默认头像、错误离线提示。录制时有主机定向测试，不作为性能基准。
- 初次 `native-entry-2221` 四场景 PASS，但 `feedback-cold-2221` 实际录像仍有灰头像交接闪回，记录 FAIL_AVATAR_HANDOFF_CONTINUITY。
- `native-entry-2221-r2` driver1/3个报告：逐帧 tester API guard 冲突及暖房未出现，不算通过。
- `native-entry-2221-r3` driver1/4个报告：头像交接 108 帧 PASS，但暖房新 SQL 读取没有开始。之后独立捕获真实取消重入竞态；不能把原日志直接说成已充分归因。
- 中间普通包 `8513ffeb…9ef5c`（产品7ada）保数据安装，UID10090/首次安装时间保持、设备 APK hash 匹配、被动检查无 fatal。`feedback-cold-2221-r2` 实际视频29.059秒，首屏有短暂图片解码占位，之后自定义头像恢复，7–11秒10fps交接检查不再灰闪、无误离线提示。`feedback-warm-room-2221-r2` 首3秒10fps显示房间首帧已有气泡，滚动历史通过。这些只证明中间产品对应行为，最终45355仍需设备复验。

合成场景含数据预置，不作为用户冷启动耗时；主入口阶段计时与原生 am start/录像时钟分开，不跨时钟相减。初次无头像缓存、旧 schema 没有成员信息时仍需正常加载一次形成新缓存，不允许跨账号旧键回退。

## 最终交付

- 普通包 `debug-main-2221-r3/final.apk`，源码45355d5f，lib/main.dart，0.4.52+2221，x86_64，126048602字节。SHA256：`042e2be1f27a535615fbe68e47be1289e7ac7a9b9e1662b653d0d8e746f1289e`；固定签名75b31c66…ba61fff。构建09:39:47–09:45:14 UTC（5分26.540秒），所有重建/语义/签名/对齐门禁通过。
- `install-main-2221-r3`：09:46:19–09:46:35 UTC保数据覆盖安装，UID10090、首次安装2026-09-26 04:06:20保持；设备APK SHA匹配。最终被动检查前台稳定、fatal0。最终版本留在普通消息列表供用户自行测试。
- `native-entry-2221-r4`：五个ID全部完成，driver0，220.625秒；所有首帧/无加载页/无误离线/头像成员断言true，头像交接112帧连续。整库preflight/opener在缓存首帧前为0，held期间消息transport0，解除后两个待发场景分别一次，隐藏/空缓存/头像场景0。取消后重入及旧清理不影响新route也已纳入实际入口断言。原生包SHA `7e32c0af34d84547007484007c113b72ae1392ff7bd0c050ca4cfa10683b81a6`。
- `feedback-cold-2221-r3`：首次安装后冷启 admissionRejected，保留为 NOT_CACHE_FAST_PATH；未绕过安全校验。正常生成新缓存后，`feedback-cold-2221-r4` cacheHit1064ms、首内容1375ms、完整SDK4078ms（同main_entry时钟，仅该次观测）。首12秒4fps及交接5–11秒10fps采样检查：真实自定义头像连续、无灰闪、无错误离线、无应用加载页；视频实际PTS时长45.001秒与请求录制35秒有模拟器差异，不作精确延迟基准。
- `feedback-warm-room-2221-r3`：首3秒10fps确认首个房间画面已有气泡且无本地消息加载页；4–8秒滚动接触表确认历史变化。未发送真实消息。

工作完成，等待用户自行测试反馈。缓存缺失、失效或身份校验不通过仍走安全恢复路径；不宣称所有冷启动零耗时、首次无缓存也命中、或所有视频帧均已人工检查。原生逐帧断言和实际录像的证据范围分别记录。V/W临时映射及本任务ADB转发已清理。
