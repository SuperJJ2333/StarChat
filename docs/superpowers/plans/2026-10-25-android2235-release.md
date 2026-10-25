# Android 0.4.66 (2235) 安装包交付计划

> For agentic workers: execute the established packaging workflow inline; specification review precedes independent quality/security review.

**Goal:** 将已验证的消息排序、群聊缓存与统计助手修复交付为新版正式 ARM64 APK，不推送更新提醒。

**Architecture:** 复用干净候选9fae7025，业务代码不变，只递增pubspec/app_config版本。源码构建→Apktool2.12.1常规重建→build-tools36.0.0对齐→既有75b31固定证书签名→身份/语义/资产门禁。线上下载范围按用户回复单独执行，不调用更新设置发布。

**Tech Stack:** Flutter3.44.9/Dart3.12.2、Java17、Android36、Python3.12、PowerShell7。

**Spec:** 本轮用户“更新新版本Android安装包，暂不推送更新提醒”；docs/runbooks/mobile-delivery-workflow.md、android-apk-rebuild.md、mobile-release.md。

## 所有权与约束

- 复用 maintenance-completion 工作树，新分支codex/android2235-release-20261025；主树既有516条状态不动。
- 生产源码只改 apps/mobile_flutter/pubspec.yaml、lib/core/app_config.dart；文档本计划、对应任务/报告及current-state新条目。构建证据仅放 docs/verification/artifacts/2026-10-25/android2235-release。
- 固定包名com.liuhetong.mobile，standard release、仅arm64-v8a、lib/main.dart，三个HTTPS公网参数及既有性能指标开关；无混淆/加壳，无资金或密钥协议改动。
- 不改更新提醒、最低版本、iOS包/设置；不合并、不强推、不改写历史。线上下载切换与更新提醒是不同操作，前者等待交付范围回复。
- Ruling：用户已授权执行现成打包流程，直接按已批准runbook执行；不另行征求实施方式确认。

## 步骤与验收

- [ ] 读取当前线上/本地/远程分支与CI版本；预检工具、磁盘、固定签名材料及设备。2234为既有iOS候选，预留0.4.66+2235，不覆盖原工件身份。
- [ ] 用bump_version.ps1成对递增版本，运行版本与Android边界测试；按输入SHA复用上轮6410共享测试，版本影响单独补验，提交冻结源码。
- [ ] 使用独立输出/framework执行完整源码构建和固定重建签名流程；每步检查退出码，记录原生/Flutter资产及清单/DEX语义对比、包名/版本/ABI/签名/对齐与源前后哈希。
- [ ] 规格审查通过后进行质量/安全审查；记录真机缺口，不用模拟器或静态验证冒充ARM64真机验收。
- [ ] 交付最终APK与SHA/证书/报告；若用户选择更新下载，按新鲜基线、备份、不可变上传与平台隔离验证执行，保持更新提醒设置不变。

## 审查重点

版本占用与身份连续性；正式包不含调试入口；测试产生的插件注册不进入包；源APK与重建包清单/DEX/原生和资源一致；更新下载不得触发弹窗或更改iOS；历史未通过的原生/设备事项如实保留。
