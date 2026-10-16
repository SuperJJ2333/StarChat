# Android 交互缓存启动与入房 Debug 交付

状态：实现、独立规格→质量/安全复审、全量 Flutter 检查、固定签名重建及模拟器保数据安装完成；用户人工体验验收待反馈。2026-10-16 23:19:17+08 安装并启动成功，23:19:29 被动运行检查通过。

## 行为与边界

- 有效本地账号通过必要的安装连续性、身份、密钥及存储检查后，使用稳定的缓存首页，恢复期间可切换页面和进入已有会话。
- 会话先使用有界本地消息头（40条），完整恢复在后台完成；当前滚动窗口、控制器、锚点和待发事务ID保持。解密结果可更新恢复前/过程中创建的固定历史窗口。
- 本地安全存储就绪后，文字发送先持久入队并显示待发送，通信就绪后沿现有权限与E2EE链路派发；恢复期间不冒称送达、不重复创建事务。新增早期队列仅覆盖文字。
- 本地磁盘、身份、密钥检查仍需时间，可能显示最初的安全加载状态；不承诺冷进程绝对零等待。首次无缓存、失效及错误状态如实展示。
- 退出/切账号、历史代次改变、撤销、销毁、事件替换/撤回等均拒绝过期回调。未改变加密算法、密钥恢复或明文持久化政策。local-only限制业务授权与派发，不等于断网；既有账号范围的Matrix媒体只读请求可能在检查后发生。

## 源码与成品

工作树 `C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat`，分支 `codex/interactive-cache-startup-20261016`，基线74cf7217，最终产品源码 **c29597e0add39d9d4deff94ef3fdda714e5c6641**。后续文档提交不改变该包源码。

| 项目 | 实际结果 |
|---|---|
| 版本 | 0.4.49+2218，普通main入口Debug |
| 包名/架构 | com.liuhetong.mobile.debug / x86_64，匹配模拟器请求 |
| 成品 | [final.apk](artifacts/2026-10-16/interactive-cache-startup/debug-main-2218/final.apk)，125,983,066字节 |
| APK SHA256 | e5de14ae36afbdf8f465ac5411ba8d76b39cc3a762c8a56d88e2f7e8b86115a6 |
| 固定证书 SHA256 | 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff |
| 安装 | emulator-5556，adb install -r，2216→2218；未卸载/清数据/降级 |
| 数据连续性 | UID10090、firstInstallTime2026-09-26 04:06:20前后一致；设备base.apk SHA与成品一致 |
| 启动 | am start -W Status ok，TotalTime4612ms；仅活动启动指标，不代表缓存首绘或性能提升测量 |
| 被动检查 | 当前进程存活稳定、主Activity前台、当前进程fatal匹配0；截图人工查看已展示原消息列表，未记录/转述聊天正文 |
| 发布范围 | 仅模拟器Debug；未发布正式渠道，未生成iOS包，未发送真人收件人消息 |

构建流程：Flutter3.44.9/Dart3.12.2、JDK17.0.20.8；保留三项HTTPS构建地址；Apktool2.12.1完整解包重建→build-tools36.0.0 zipalign-P16→固定证书签名→验签/对齐/包身份/重解包语义检查。27,386类、177,848方法保留，27DEX清单保持，274原生库/资产条目字节一致，475资源条目保持，清单语义一致。DEX二进制重编译变化不等于业务代码变化，严格归一化范围见检查日志。

## 验证证据

下列相对证据位于 [artifacts/2026-10-16/interactive-cache-startup](artifacts/2026-10-16/interactive-cache-startup)。

| 范围 | 结果及证据 |
|---|---|
| 最终全量Flutter | **6075PASS / 9SKIP / 0FAIL**，full analyze无问题，均exit0；flutter-full-4/receipt.json、summary.json、flutter-full.log、flutter-analyze.log |
| Task1房间/入队 | 持有真实本地头与完整恢复、撤销租约、无加密拒绝、派发前readiness竞态RED→GREEN；task1及fix1，最终74PASS、SPEC→QUALITY通过 |
| Task2启动/导航 | 71专项PASS；outbox开启跨验证竞争补充23PASS；分析清洁，task2/fix1/review.md通过 |
| 最终复审修复 | retained40解密/no-broadcast及readiness行缓存；final-fixes/report.md，初轮63PASS；真实规模N1000/10000/100000、媒体10场景、手势2项证据保留 |
| 固定窗口补充 | 真实密钥+真实密文，无广播，先pin/解密中pin/隐藏消息，12fragment竞态；有效RED30/40与39/40→最终78PASS，4文件分析无问题；final-fixes/pinned/report.md、review.md，SPEC→QUALITY/SECURITY通过 |
| 移动边界/UI契约 | 2f6b625c上377PASS23SKIP、34components/540screens PASS；最终SDK变更另2PASS，pinned-sdk-boundary.json；其他输入未变复用 |
| HTML | 新交互6PASS；浏览器确认切页、入房返回、pending→retry→ACK同气泡；全量563PASS/6FAIL，精确74cf7217基线同6旧下载/签名断言失败，非全仓通过 |
| 仓库/部署政策 | PASS，final-preflight.json；完整verify.ps1因缺.env预检未启动，不能声称其通过 |
| APK构建 | debug-main-2218/receipt.json、step-timings.jsonl、signature.log、alignment.log、identity.log、rebuild-verification.log，全部步骤exit0 |
| 安装/运行 | install-main-2218/receipt.json、launch.log、passive-smoke.json；设备截图仅本地忽略证据，不入Git |

依赖锁SHA a43833c8e7c3d6faa93d21babdc61dfe4b3563c7ac00912006f26daa8e0ecc5d保持。Host原生测试沿用经哈希确认的Olm3.2.15、SQLCipher4.10.0/SQLite3.50.4；精确SHA在full-4收据。SQLCipher用例是真实FFI内存数据库，不冒充加密磁盘或实体手机测量。

早先full-1因队列竞态修复取消；full-2在6025PASS/9SKIP/23错误后中止（18个缺失的忽略夹具父目录、5个房间夹具/退役回调问题及手势等待），均已修正；full-3因固定窗口P2取消。它们不是通过记录，原日志保留；最终full-4完整退出0。复审通过后才重跑最终全量，避免再次因并行修复使门禁失效。

## 计时、决策与剩余验收

| 阶段 | UTC区间 | 工具耗时/依据 |
|---|---|---|
| 最终全量及分析 | 14:58:55.0872308→15:11:07.9676662 | 12分12.880秒，full-4收据 |
| 构建/重建/验证 | 15:11:25.4857040→15:18:28.2578315 | 7分2.772秒，build收据；各步独立计时 |
| 保数据安装/启动 | 15:18:56.6094160→15:19:17.6683936 | 21.059秒，install收据 |

首次记录的交付预检20:59:43+08至安装完成23:19:17+08约2小时19分35秒；此前设计开始时间未知，不估造总主动工时。各轮RED/GREEN/审查/返工在progress.md及子报告留有精确时间，不把并行时间相加。

用户明确授权实施及模拟器安装，未重复请求批准。单写实施、独立规格后质量复审。技能的一次最终修复波次限制与完成原要求冲突时，依更高优先级继续原固定窗口P2，限定四文件并补RED/GREEN/复审，代价是额外验证时间。新增窄SDK接口仅为安全更新仍归属当前窗口的原事件；无全局历史窗口注册或额外持久化。

构建有既有Kotlin Gradle Plugin未来迁移提示（12插件）及依赖Java废弃API/unchecked提示，实际当前锁定工具链构建exit0。未在本次缓存行为任务中升级工具链/插件，也未压制诊断；具体列表在source-build.log。P3初始性能诊断tab归因可能unknown，明确延期，不影响显示与发送。

用户下一步：强停后冷启动并立刻切tab/入房，滚动后观察恢复是否跳位；在恢复期间发送测试文字，确认待发送→送达且不重复。实际发送需由用户执行。本任务未做真人消息发送、ARM64实体机性能或iOS运行验收；普通活动启动时间不等于首帧体验结论。

当前无本任务运行中的测试、构建、代理实现或浏览器服务；自有V/W映射均已移除。工作树和最终APK保留供继续排查。没有生产改动需回退；不以卸载/清数据/版本降级作为模拟器回退手段。
