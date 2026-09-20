# Android / iOS 构建入口

**Current · 2026-09-20**。仅规定构建职责；发布统一进入[轻量发布门禁](release-metadata.md)。构建成功不等于最终企业包或真机安装通过。

## 先确定版本和构建来源

按[移动交付总流程](mobile-delivery-workflow.md)读取任务状态。版本由 `scripts/bump_version.ps1` 同步更新 pubspec 与 app_config；执行 `tests/mobile/test_app_build_contract.py`。不得把旧文档中的版本、镜像、签名或工具版本当成本次值。

## Actions 对照

| 文件 | 用途 | 发布边界 |
| --- | --- | --- |
| [android-ci.yml](../../.github/workflows/android-ci.yml) | 静态检查、测试、Debug构建 | 不代表正式包可分发 |
| [android-release.yml](../../.github/workflows/android-release.yml) | 签名构建、候选工件；可选上传 | 仍须遵守固定重建/签名要求，不等于弹窗发布 |
| [ios-0353.yml](../../.github/workflows/ios-0353.yml) | iOS signed compatibility candidate | 历史文件名不固定版本；TestFlight上传关闭 |
| [ios-testflight.yml](../../.github/workflows/ios-testflight.yml) | 模拟器/IPA/TestFlight | 手动运行同时启动unsigned IPA和上传任务，不是单纯企业分发 |
| [release-metadata.yml](../../.github/workflows/release-metadata.yml) | 发布记录与线上小文件检查 | 不构建、不下载安装包、不自动发布 |

## Android

遵循[APK固定打包流程](android-apk-rebuild.md)：源码构建、常规重建、对齐、固定签名。版本/包名/ABI/工具以该流程和实际构建记录为准。旧多ABI、旧证书及旧release脚本只作为历史，不复制到新发布。

生产源码构建必须保留公网配置：`LIUHETONG_BUSINESS_API_URL=https://liuhetong888.com`、`LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888.com`，以及项目规定的Getui公网参数。禁止将localhost、局域网或明文HTTP地址写入正式包；Business API基地址不附加`/api/v1`，路径由客户端负责。

## iOS

企业分发：构建候选 → 交付企业重签 → 由交接方确认最终版本、大小、Bundle ID与签名身份 → 准备release JSON → 轻量发布。按用户2026-09-20要求，发布阶段不重复下载安装包验包；确认不等于工具已验签。

TestFlight：使用对应Action及受保护Secrets；签名证书/描述文件和App Store Connect上传密钥职责不同，不放入仓库或聊天。首次开户的[历史参考](../archive/2026-09-20/runbooks/ios-windows-testflight-setup.md)不代表当前账号仍待配置。Action实际文件是触发条件和Secret名称的依据。

## 历史

[旧构建说明](../archive/2026-09-20/runbooks/mobile-release.md) · [旧CI/发布总说明](../archive/2026-09-20/root/RUNBOOK_RELEASE.md)。历史中完整回拉验包、直接调用旧publisher的要求均不再适用。
