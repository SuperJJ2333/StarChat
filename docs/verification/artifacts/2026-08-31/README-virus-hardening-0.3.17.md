# 2026-08-31 0.3.17+20 发布（病毒告警加固）与跟踪说明

## 现象

用户手机安全软件（国内厂商引擎）报 `a.gray.BulimiatGen.f` 灰度病毒告警。
该家族为启发式判定（非确认型木马），Flutter 应用常见误报诱因：
明文 APK 下载/安装相关字符串、高熵未知原生库、敏感权限组合、缺少混淆信息。

## 本轮加固（0.3.17+20）

1. **R8 混淆 + 资源收缩**（`android/app/build.gradle.kts` release 开启
   `isMinifyEnabled/isShrinkResources` + 新增 `proguard-rules.pro`，
   保留 Flutter/SQLCipher/WebRTC/record/speech_to_text/通知 等 JNI 按名绑定与行号信息）。
2. **Dart 代码混淆**：官方构建脚本追加 `--obfuscate --split-debug-info=build/symbols`
   （去除 libapp.so 明文字符串/符号，符号表存档用于崩溃还原）。
3. 权限保持收敛（无 REQUEST_INSTALL_PACKAGES/SYSTEM_ALERT_WINDOW/READ_PHONE_STATE，
   应用内更新经外部浏览器下载，无静默安装行为）。

## 发布

- 版本 0.3.17+20；arm64 SHA256 以服务器 `latest-arm64.apk` 与本地构建比对一致；
  `latest-*.apk` 符号链接已指向 0.3.17；更新设置 LATEST=0.3.17/20 已下发（幂等键
  app-update-publish-0.3.17-20260831）；外部验证 PASS。
- 回归：客户端 439 项全过、analyze 零问题（混淆为构建期行为，不改 Dart 逻辑）。

## 用户侧说明

- 重新下载安装 0.3.17 后，部分厂商引擎若仍提示，属厂商灰度误报：
  可在管家内"信任/加入白名单"，或向厂商提交误报申诉（提供 APK 与签名证书）。
- 我们保留向腾讯/360 误报申诉通道提交的权利；如厂商仍拦截，提供管家名称与
  拦截截图以便进一步定位具体规则。

## 待办

- [ ] 观察 0.3.17 用户侧告警反馈；若主流厂商仍拦截，评估接入厂商推送/应用商店分发
      （商店渠道有官方杀毒白名单）。
