# 账号 UI Debug 模拟器安装

## 恢复入口

- 授权：用户在四项UI正式实现后明确“请你推送到debug版到模拟器安装”。允许本地Debug打包、固定签名和保留数据安装/启动当前模拟器；不包含生产API/worker发布或真实验证码发送。
- 来源：[账号UI实施任务](2026-09-26-account-ui-implementation.md)、[批准计划](../../superpowers/plans/2026-09-26-account-ui-implementation.md)、[固定APK流程](../../runbooks/android-apk-rebuild.md)。源码基线HEAD `b9eca8a419614112b085439445b7fd031027a740`。
- 所有权：父代理领取隔离工作树的Android构建快照及版本两字段、此次打包脚本/证据/记录。子代理只读核对已有重建/验包工具。保留原D盘其他修改；不并行编辑同一文件。
- 工作树：复用 `C:/Users/Administrator/.codex/worktrees/account-ui-implementation/StarChat`；构建前同步D盘已集成移动端快照、强制原依赖锁。最终包以该快照身份为准，不使用上一轮0.4.6编译中间APK。
- 当前状态：最终0.4.14/2181已重建、固定签名、保留数据安装并启动；最终身份以下方新证据为准。
- 设备：`emulator-5556` online，Android9，ABI含arm64-v8a。现包 `com.liuhetong.mobile.debug` 0.4.13/2179；firstInstallTime/lastUpdateTime均2026-09-26 04:06:20。
- 签名：现包工具实测证书SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，与固定身份相同。无卸载、清数据、降级或生成新密钥。
- 开始观察：2026-09-26 17:55:31 +08:00；17:57:19确认现版本；固定签名读取通过。下一步：升版、源码构建→Apktool→对齐→固定签名→完整验包→adb install -r→包身份/启动读回。

## 计划与验收

- [x] 同步候选、版本/锁门禁与相关输入身份；复用已通过4002完整Flutter和回填62测试，对快照增量补相关回归。
- [x] 0.4.14/2181 standard Debug ARM64构建，`chatflowParallelDebug=true`保留.debug包名；Business/Matrix/Getui三项HTTPS参数。
- [x] Apktool2.12.1独立framework/输出，zipalign36，固定证书；manifest/ABI/DEX/Flutter资产/签名验证。
- [x] ADB保留数据覆盖安装，读回版本/首次安装时间/包内SHA，启动无崩溃。
- [x] 更新任务、报告、current-state；交付实际安装结果与剩余业务验收边界。

## 证据与复用

证据仅在 `docs/verification/artifacts/2026-09-26/account-ui-debug-emulator/`。上一轮源码/领域/质量、Flutter4002、frontend316、PG9、worker/OpenAPI128等见正式报告；服务端及UI逻辑不因打包重跑。版本与打包输入变更需要本轮新构建/验包，模拟器安装不等于真实验证码或真机验收。前置旧包已读回用于签名匹配，未读用户数据。

精确阶段计时及最终包SHA/安装状态在实际执行后回填；未知阶段不推算。固定密钥和DPAPI不进入仓库或输出。

## 最终执行记录

- 用户继续授权后，发现设备已有0.4.13/2180；候选升至0.4.14/2181。现有包再次拉取核验固定签名，安装前设备SHA与该核验样本一致。
- Gradle全局false覆盖env导致首份包名错误；构建进程system属性覆盖修复，历史包未安装。最终源码编译exit0/21.42秒；paired version2PASS、analyze0问题13.2秒、相关64PASS7秒。
- 重建16步骤exit0，合计79.13秒；27317类/339原生资产一致，25DEX及resources确实重建，manifest语义/ABI/固定签名/对齐通过。
- install-r Success/4.99秒；设备读回SHA `8f675d11e1551d1ebfa33893124071bc5d1a8c16bd926da214c33a9ffc05a21f`，首次安装时间保持2026-09-26 04:06:20，0.4.14/2181启动Status ok/PID8772/前台MainActivity正常，观察5秒后本包crash0。
- 安装前脚本单行字符串索引问题已修正，首尝试未安装；原始失败日志保留。版本两处安全回填D盘，其余源码未改；候选与原工作区29快照项未发生非版本漂移。
- 详见[最终报告](../../verification/2026-09-26-account-ui-debug-emulator.md)、[验包](../../verification/artifacts/2026-09-26/account-ui-debug-emulator/verification.json)、[安装步骤](../../verification/artifacts/2026-09-26/account-ui-debug-emulator/installation.json)。
- 完成观察UTC `2026-09-26T13:59:56.6118777Z`。下一步：用户在模拟器审阅；生产OTP API/worker及真实双渠道验收未做。无Git推送/生产发布/真机安装。

- 安装传输闭环：流式会话2010463178持续停在0.69145685，终止已核对身份的本任务客户端；abandon返回无访问，随后现场无活跃会话。改用--no-streaming -r，3.305秒推送及4.99秒安装Success，旧数据保留。
