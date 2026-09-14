# 2026-09-14 Android 0.3.89/2111 发布与两项体验修复

## 背景

发布请求：Android 更新弹窗 + iOS IPA 交付企业签名。期间用户追加报告两项问题，纳入本发布（2110 构建含四项体验修复但未含追加修复，已被 2111 取代；2109 及更早为 debug 交付）。

## 追加修复（commit b4f65404）

1. **顶部导航栏下方“正在加载”icon**：根因是 `WeChatPageScaffold.navigation` 在每个页面导航栏下固定挂网络状态胶囊，“connecting”态渲染“正在连接…”转圈胶囊（Mi 6 实测截图确认）。修复：胶囊新增 `showConnecting` 门控，页面脚手架传 false——“正在连接”不再出现在导航栏下方；真正离线（“网络不可用，联网后自动重试”）与服务不可用提示保留。媒体查看器等处的胶囊行为不变。
2. **快速切换页面后点会话无响应**：Mi 6 打点实测（probe 构建）显示点击后 `openRoomLease` 取租约需 0.8~1.4 秒，期间无任何 UI 反馈且 `_openingRoom` 守卫吞掉重复点击——用户感知为“点了没反应”。修复：点击立即弹出轻量居中转圈覆盖层，租约就绪 pop 覆盖层并进入房间；打开失败同样 pop 并保留原有错误路径。重复点击仍被守卫阻断但现在有明确等待视觉。
自测：新增 `network_status_capsule_test`（connecting 不渲染/离线渲染/恢复消失三段断言）；Flutter 全量 2669 通过；Mi 6 真机复核——导航栏下方无胶囊、点会话立即出现转圈随后进入房间。

## Android 0.3.89/2111 发布

- 版本 0.3.89+2111（pubspec `c21af3d6`），含四项体验修复（闪照/转发异步/启动外壳/账单对比度，`8b3559f4`）与本两项修复。
- 构建遵循 android-apk-rebuild 固定流程：`flutter build apk --release --flavor standard --target-platform android-arm64` + 三项 HTTPS dart-define；Apktool 2.12.1 重建、zipalign 36.0.0 `-P 16 -f 4`、固定证书 `75b31c66…` 签名；aapt 验证 `com.liuhetong.mobile` versionCode 2111 / versionName 0.3.89 / arm64；源与重建包语义验证通过。
- SHA256：`A9CBEBDD02D0037B6822A56780413174096E6FC209A313D1AC3B4F804830F333`（79,211,550 字节）。
- 上传：16MB 分块经跳板顺序上传，服务端合并 SHA 门通过后 `install -m 0644` 为 `/opt/starchat/frontend/downloads/ChatFlow-0.3.89-build2111-arm64.apk`；`latest-arm64.apk` 符号链接原子切换至 2111；旧包 2085/2089 保留（回退路径）。早前误存的 2110 APK 已清理（其设置从未指向有效文件时的 2110 记录被本次发布覆盖）。
- 更新弹窗（SettingService set_many，trace `android-release-0.3.89-2111-20260914`，5 条审计）：latest_version 0.3.89 / latest_build 2111 / min_supported_build 3（沿用原值）/ notes（≤255 字符：闪照、转发提速、启动加载与账单筛选优化、相册滑动多选）/ apk_url 指向版本化 2111 APK。inspect→apply 两段执行，iOS 行（app_ios_*）核对未被改动。
- 公网验证：服务器与工作站（jumper SOCKS）双侧 `ChatFlow-0.3.89-build2111-arm64.apk` 与 `latest-arm64.apk` 均 206 + application/octet-stream（Range 探测 Accept-Ranges 生效）；旧包 2089 仍 200；`GET /api/v1/app-updates/latest?platform=android` 未授权 401 AUTH_REQUIRED（路由存活）；端点投影读回 latest_build=2111 且 apk_url 正确。

## iOS

- `ios-0353.yml`（iOS signed compatibility candidate）由 main 推送自动触发，2110 版本 run 34825452768 成功、2111 版本 run 34838665737 排队中。完成后下载待签 IPA（App Store 团队签名，仅供企业重签），交付用户回传企业签名包后再更新 manifest.plist 与 iOS 设置——与 2085 流程一致，iOS 设置须待企业签名 IPA 实装后再发布。

## 遗留

- 用户真机验收：闪照全链路、转发提速体感、启动无“正在加载”残留、点会话立即反馈。
- iOS 企业签名回传后的 OTA 发布为独立事务。


## iOS 待签 IPA 交付（2026-09-14 20:00 前后）

- GitHub Actions run `34838665737`（commit `c21af3d6`，0.3.89+2111）success；artifact `ChatFlow-iOS-signed` 59,432,386 字节，解包后 `liuhetong_mobile.ipa` 59,810,103 字节。
- 交付文件：`docs/verification/artifacts/2026-09-14/release-2111/ios/ChatFlow-0.3.89-build2111-for-enterprise-resign.ipa`
- SHA256：`BEAF4F6BD5312B606A851BEF24A51446BEFAF1498B7E94B2A5B2E903C323D283`
- 包内核验：bundle id `com.liuhetong.liuhetongMobile`、version 0.3.89、build 2111、SQLCipher framework 在位；统计 HTML SHA `89eab232…` 与 Android 2111 包及已发布资源一致。
- 签名状态：App Store 团队签名（enterprise=false），仅供企业重签。请完成企业签名后回传；回传包核验（安装兼容、entitlements、嵌入库）通过后再更新 manifest.plist 与 iOS 更新设置（独立事务）。
