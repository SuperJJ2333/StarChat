# 雷电 Debug 安装交付

## 恢复入口

- 授权：用户要求“请你推送debug版本到雷电模拟器，让我自行测试”。
- 计划：[冷启动发送 Debug](../../superpowers/plans/2026-10-27-cold-send-debug.md)。
- 状态：Debug 构建、校验、保留数据覆盖安装及冷启动完成，待用户聊天体验反馈。工作树 C:/Users/Administrator/.codex/worktrees/maintenance-completion/StarChat，分支 codex/cold-send-debug-20261027。
- 源码：运行修复 7b6a894b、冻结头 c6bdc617；本轮不修改移动端代码。仅持有计划、本记录、验收报告和 current-state 新条目。
- 最后更新时间：2026-10-27 17:23 +08:00。下一步：用户在“畅聊 Debug”自测冷启动直接进入群聊、历史未就绪时发送及本人右侧气泡；收到反馈后沿源码任务定位。

## 验收台账

| ID | 要求 | 状态 |
| --- | --- | --- |
| D1 | 已验证最新源码、依赖和证据身份 | PASS：1721 个既有验证输入一致，2158 个构建输入前后一致；上轮环境缺口保留 |
| D2 | standard Debug / x86_64 / 固定签名 / 重建验证 | PASS：17 步 exit0；DEX/清单语义及274资产/原生条目一致；Debug kernel 为本次新程序 |
| D3 | 保留数据覆盖安装、真实入口启动 | PASS：2233→2235，UID10090、firstInstallTime 2026-09-26 04:06:20 保持；设备 APK SHA 一致，MAIN/LAUNCHER 冷启并在前台 |
| D4 | 用户自测及可追溯交付 | 包及[验收报告](../../verification/2026-10-27-cold-send-debug.md)已保存；真实聊天待用户操作反馈 |

## 版本与证据

目标 0.4.66+2235、com.liuhetong.mobile.debug、x86_64，当前雷电 emulator-5556 支持 x86_64。本地 Debug 独立于官网下载的同版本 ARM64 正式包，不改变发布状态。

证据根：D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-27/cold-send-debug/。原包 installed-before.apk 仅为签名基线，不是数据库备份。固定证书 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff。

最终包 debug-main-c6bdc617/final.apk，126163290 字节，SHA256 3ac0f1b23a5d4cb902eb12484bbb9fd9957cb27262c81c852e847b4db67f58bf；source_commit c6bdc6178b92ce8bf3ea54ba6dbeb0cc897b844b，运行修复 7b6a894b。未调整版本对、源码、官网或提醒。

## 阶段计时与交接

构建 17:15:00–17:20:36 +08:00，336.47 秒；安装/冷启动 17:22:13–17:22:33，19.62 秒。计时来自 receipt.json / device-install-receipt.json，前期阅读未精确计时。规格→质量/安全由根代理顺序复核本次工件与安装脚本，非新增独立源码审查。构建 W: 映射已释放，无本任务持续运行构建。

未变输入复用源码报告中完整 Flutter 的通过及失败文件补跑证据，原全量 exit1、总 verify 缺 .env、Ruby 缺失均保留，不宣称所有门禁一次通过。插件的未来 Kotlin 迁移及旧 API 编译警告保留，未为本次安装改动依赖。不得通过卸载、清数据或降级解决后续错误；outbox v3 向前升级边界见[源码报告](../../verification/2026-10-27-cold-room-send-identity.md)。
