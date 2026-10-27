# 雷电冷启动发送 Debug 交付计划

用户于 2026-10-27 明确要求将 Debug 版本安装到雷电模拟器自行测试。该授权覆盖构建、固定身份签名、保留数据覆盖安装和启动；不包含生产分发或更新提醒。

1. 复用已验证运行源码 7b6a894b（文档头 c6bdc617），核对源码及依赖锁与冷启动发送验证证据一致。候选工作树没有 .codegraph，不创建索引。主工作树既有改动保持。
2. 使用当前 0.4.66+2235 构建 standard / lib/main.dart / Debug / x86_64，包名 com.liuhetong.mobile.debug，标签“畅聊 Debug”。设备原 Debug 为 0.4.64+2233，故本次为递增覆盖升级。它不是新正式版本，源码和 APK 身份独立于官网 2235。
3. 正常恢复 Flutter 依赖和生成配置、强制锁文件，冻结输入。执行 Apktool 2.12.1 完整重建、36.0.0 zipalign 16KiB 和固定 75b31 证书签名，检查清单、DEX 语义、原生/Flutter 资产及源输入一致性。
4. 先规格、后质量/安全核对交付。确认 emulator-5556 在线、原签名一致、没有版本降级后执行 adb install -r。核对安装 SHA、UID 和 firstInstallTime，启动真实 MAIN/LAUNCHER。不卸载、不清数据、不代发消息。
5. 更新任务、验收报告和 current-state，交由用户验证冷启动发送、右侧本人气泡、历史加载和群聊体验。构建/安装通过不等于真实聊天验收通过。

文件所有权：上述计划、对应 workflow task / verification 报告、current-state 新条目；非 Git 构建/安装证据仅放 D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-27/cold-send-debug/。不改业务源码或版本元数据。

复用限制：上轮完整 Flutter 为 6421 PASS / 9 诊断跳过 / 1 Windows 清理失败，未变输入整文件补跑 12 PASS；analyze 和移动边界通过。总 verify 缺 .env、Ruby/iOS 平台条件未满足，不将其写为通过。新包首次运行会沿现有升级路径迁移 outbox v3；旧 v2 二进制不能以清数据库方式回退。
