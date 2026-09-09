# 统计助手 HTML 补发 Android 正式版

状态：用户明确要求将指定主目录 HTML 更新后推送 Android，按该授权执行。iOS 不发布。

拥有文件：`apps/mobile_flutter/assets/html/statistics_tools_combined_v2.html`、`apps/mobile_flutter/pubspec.yaml`、`apps/mobile_flutter/lib/core/app_config.dart` 版本默认值、本计划及对应验证报告。只导入用户指定 HTML，不混入主目录其他未提交工作。

1. 复现发布工作树和 2070 APK 使用旧 HTML；以中文金额输入及自绘确认流程作失败回归。
2. 原字节同步指定 HTML 到发布工作树，版本递增 0.3.68+2072，浏览器功能回归与 Flutter 统计助手测试；执行仓库验证。2071 在预发布检查中发现 app_config 版本默认值未同步，因此不启用其更新配置；2072 同步两处版本信息。
3. 从源码 release 构建，按 Android runbook 重建、对齐、固定签名。断言最终 APK 内目标 HTML 与用户文件字节一致，其他原生库/资产及清单满足重建语义校验。
4. 先规格复核（目标文件/功能/版本/仅 Android），再质量与安全复核（脚本运行、会话缓存、签名、不混入其他代码）。
5. 私有暂存及三端哈希校验后，以应用服务事务更新五项配置及审计，原子更新 latest，保留旧版与回退证据。

执行结果：以上步骤完成，正式发布 0.3.68 / 2072；细节、红绿证据及验证边界见 `docs/verification/2026-09-09-statistics-android-0.3.68.md`。
