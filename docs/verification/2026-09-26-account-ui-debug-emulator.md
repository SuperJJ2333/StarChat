# 账号 UI Debug 模拟器安装验证

## 实际结果

已将 **畅聊 Debug 0.4.14 / 2181** 保留数据覆盖安装到 `emulator-5556`，启动成功，进程和前台 Activity 正常。本次启动后的 crash buffer 未检出本包崩溃记录。用户明确授权本地 Debug 打包、固定签名、模拟器安装；未部署生产 API/worker，未真实发送验证码。

承接[正式实现](2026-09-26-account-ui-implementation.md)及[安装任务](../workflow/tasks/2026-09-26-account-ui-debug-emulator.md)。账号 UI、固定左标签、设置分组和忘记密码入口已包含于此包；真实邮箱/手机验证码业务需配套后端发布及后续验收。

## 身份

| 项目 | 实测身份 |
| --- | --- |
| 工作树 | `C:/Users/Administrator/.codex/worktrees/account-ui-implementation/StarChat` |
| Git 基线 | `b9eca8a419614112b085439445b7fd031027a740` |
| 源码身份 | [2181逐文件SHA](artifacts/2026-09-26/account-ui-debug-emulator/mobile-build-source-identity-2181.json) |
| 包名 / 构建 | `com.liuhetong.mobile.debug`，standard Debug，ARM64，debuggable |
| 版本 | `0.4.14+2181`，两处版本元数据已回填原工作区 |
| 设备 | `emulator-5556`，Android9，ABI支持arm64-v8a |
| 最终 APK | [final.apk](artifacts/2026-09-26/account-ui-debug-emulator/final.apk)，145461547 字节 |
| 最终及安装读回 SHA256 | `8f675d11e1551d1ebfa33893124071bc5d1a8c16bd926da214c33a9ffc05a21f` |
| 源码中间 APK SHA256 | `c814cd1839859a786f1b04379d6fefd93aada9502edb4fa7e325a46be0f81848` |
| 固定证书 SHA256 | `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff` |
| 安装证据记录 UTC | `2026-09-26T13:59:56.6118777Z` |

## 验证与计时

| 阶段 | 结果 | 实测用时 |
| --- | --- | --- |
| 2181配对版本测试 | 2通过；原工作区再次2通过 | 0.12秒（候选） |
| 锁定依赖 | 两次 `--enforce-lockfile` 成功 | 未单独计时 |
| Flutter analyze | 无问题 | 13.2秒 |
| 移动端快照相关回归 | 64通过 | 7秒 |
| 最终源码构建 | exit0，Gradle16.4秒，三个HTTPS dart-define | 21.42秒（进程） |
| 重建/签名/独立解包门禁 | 全部16步骤exit0 | 79.13秒（步骤合计，非总墙钟） |
| `adb install -r` | Success，未卸载/清数据/降级 | 4.99秒 |
| 安装读回 | 哈希/固定证书/2181版本一致 | 见[安装步骤](artifacts/2026-09-26/account-ui-debug-emulator/installation.json) |
| 启动 | `Status: ok`，PID `8772`，MainActivity resumed | 启动后观察5秒，crash buffer无本包新记录 |

按[固定流程](../runbooks/android-apk-rebuild.md)使用Apktool2.12.1、Java17、build-tools36.0.0、Python3.12。顺序为完整解包→smali/DEX及资源重建→签前16KiB对齐→现有p12/DPAPI固定签名→验签及签后对齐→最终包独立解包。没有生成或轮换密钥，没有签后改包。

验包实测：27317个smali类保留，归一化仅允许既有静态默认false/整数0/null；全部方法内容一致。339个原生库/Flutter资产逐项SHA相同；完整清单语义相同；25个DEX和resources.arsc确实重建；DEX条目名集合相同；source/final均仅ARM64且含Debug kernel。详见[verification.json](artifacts/2026-09-26/account-ui-debug-emulator/verification.json)、[重建步骤](artifacts/2026-09-26/account-ui-debug-emulator/rebuild-steps.json)、[签名](artifacts/2026-09-26/account-ui-debug-emulator/apksigner-verify.log)。

安装前后首次安装时间均为 `2026-09-26 04:06:20`，保留安装数据；未读取聊天内容。安装后包信息：

```text
versionCode=2181 minSdk=24 targetSdk=36
    versionName=0.4.14
    firstInstallTime=2026-09-26 04:06:20
    lastUpdateTime=2026-09-26 21:59:33
```

## 过程中的问题与闭环

首轮19.6秒源码编译成功但包名未取得`.debug`，身份检查拒绝，未用于安装。根因是本机Gradle全局properties已有`chatflowParallelDebug=false`，优先于环境变量；本次构建进程增加`-Dorg.gradle.project.chatflowParallelDebug=true`，未修改全局配置。恢复后的2180源码包名/标签已正确，但设备在任务间隔中从2179更新到0.4.13/2180（19:29:34），因此候选升为2181并重新编译。历史两份中间包和日志留存。

最终安装前再核对2180包的固定证书及设备APK SHA，随后覆盖安装；最终读回APK与已验包final.apk完全一致。安装脚本最初在安装前因PowerShell单条字符串解包后索引成字符失败，修正显式数组包装后继续；失败日志保留，首个脚本尝试没有安装。

流式安装会话2010463178的传输进度持续停在0.69145685，设备仍为旧版且ADB可响应；仅终止已核对身份的本任务ADB安装客户端。随后对该会话的abandon请求返回Caller has no access，后续现场无活跃会话，旧安装版本/首次安装时间不变。改用`adb install --no-streaming -r`后3.305秒推送、安装Success，完成全部读回门禁。未卸载、清数据或并发重发安装。原流式失败日志和进度观察保留。

构建日志存在第三方插件Kotlin Gradle Plugin未来兼容性提示；当前工具链构建成功，依赖未升级。此前完整Flutter4002等源码证据复用正式实现报告，本轮没有冒称重新执行完整verify。

## 后续边界

本次完成本地Debug包和模拟器安装。生产OTP后端未发布、真实邮箱/短信验证码与真机/iOS尚未验收；此安装结果不代表这些链路已通过。未提交或推送Git远端，未更新官网正式分发。后续可在模拟器审阅UI；如需真实验证码流程，下一独立步骤是发布已验证的配套账号API/worker并执行受控业务验收。
