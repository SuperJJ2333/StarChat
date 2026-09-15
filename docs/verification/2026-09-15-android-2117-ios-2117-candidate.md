# 2026-09-15 Android 0.3.91/2117 发布 + iOS 2117 待签 IPA 交付

## 范围

在 0.3.90/2115 基础上新增：会话切换 5 秒阻塞根因修复（租约取消移出关键路径，
commit `36c3e6f3`）、版本比较 debug 后缀修复（`ab50f4e9`）及 Mi 6 已验收的全部既有改进。
版本 0.3.91+2117（pubspec `370a83cb`，app_config 同步 `2082747f`）。

## Android 发布

- 固定流程构建：ARM64 正式包，aapt 验证 `com.liuhetong.mobile` 2117 / 0.3.91 / arm64；
  语义验证、发行门禁、固定证书 `75b31c66…` 全部通过。
- SHA256：`AA02B144757997CE866FCBE52229793892B1440A75D33E63FB2A77842A5C6748`（79,277,086 字节）。
- 分块上传 → 服务端合并 SHA 门一致 → `install -m 0644` 为
  `/opt/starchat/frontend/downloads/ChatFlow-0.3.91-build2117-arm64.apk`；
  `latest-arm64.apk` 切换至 2117；2115 及更早保留（回退路径）。
- 更新弹窗（trace `0.3.91-2117-20260915`，5 条审计）：0.3.91/2117，
  min_supported_build 3 沿用，apk_url 指向版本化 2117 包；iOS 行未改动。
  本次 client_projection **含 `platform: "android"`**（昨日服务端修复生效，客户端校验可通过）。
- 公网验证（服务器 + 工作站 SOCKS 双侧）：2117 包与 latest 均 206 + 正确 MIME；
  2115 保留 200；未授权 401 存活。

## iOS 待签交付

- GitHub Actions run `34928011287`（commit `2082747f`，0.3.91+2117）success；
  artifact `ChatFlow-iOS-signed` 解包后 IPA 59,818,072 字节。
- 交付文件：`docs/verification/artifacts/2026-09-15/release-2117/ios/ChatFlow-0.3.91-build2117-for-enterprise-resign.ipa`
- SHA256：`E393C61A6ABB50E8785A24CD6AE8593DA560B465B3A88E768DE764818CD89D4D`
- 包内核验：bundle id `com.liuhetong.liuhetongMobile`、version 0.3.91、build 2117、
  SQLCipher 在位、统计 HTML SHA `89eab232…` 与 Android 包一致。
- App Store 团队签名（enterprise=false），仅供企业重签。签名回传核验后再发布
  manifest.plist 与 iOS 设置（独立事务）。


## iOS 0.3.91/2117 企业分发（2026-09-15）

用户回传企业签名包 `ChatFlow-0.3.91-build2117-enterprise.ipa`
（SHA256 `8e207d61c7f94ae2f929b4138016ade1abdbd0373ef4f21eb18c9c6a4baf87d2`，60,443,999 字节）。

核验：embedded.mobileprovision 与已安装成功的 2085 企业包**完全一致**
（20260107buaawxworklocalNOTI / Team ZXB3TS7QD4 / ProvisionsAllDevices 企业分发 /
到期 2026-12-03 / aps production），签名身份兼容覆盖安装；
bundle id `com.liuhetong.liuhetongMobile`、0.3.91/2117、SQLCipher 在位；
统计 HTML SHA `89eab232…` 与 Android 包一致；
与待签包资源对比仅 Mach-O 重签差异与已知签名通道新增项
（ATHelper.dylib / libutils.dylib / flag，与 2073/2085 相同），Flutter 资产零变化。

分发：

- 安装为不可变版本文件 `/opt/starchat/frontend/downloads/ios/ChatFlow-0.3.91-2117-enterprise-8e207d61.ipa`
  （分块上传 + 服务端合并 SHA256 门一致）。
- `manifest.plist` 以 `.new` 暂存、plist 校验通过后原子换入：software-package 指向
  2117 企业 IPA、bundle-version 2117；旧 manifest 备份为 `manifest.plist.bak-20260915`。
- iOS 更新设置发布（trace `ios-enterprise-0.3.91-2117-20260915`，5 条审计）：
  app_ios_* → 0.3.91/2117，下载 URL 保持下载页
  `https://www.liuhetong888.com/download?platform=ios&install=1`；
  Android 行核对未被改动（2117）。设置前备份已从容器 /tmp 拷贝至宿主机
  `/opt/starchat/docs/verification/artifacts/2026-09-15/appupdate-platform-fix/settings-before-ios-2117.json`（0600）。
- 公网验证：IPA 206 + application/octet-stream（Range 探测）；manifest 200 +
  application/xml 且内容含 2117 与 8e207d61 IPA URL；下载页 200；
  `app-updates/latest?platform=ios` 未授权 401（路由存活），
  授权投影读回 0.3.91/2117。

## 待办

- iPhone 真机覆盖安装、登录（ADR-0068 门禁）、闪照/会话切换由用户验收。
- 回退：恢复 `manifest.plist.bak-20260915` 与 2085 企业 IPA（保留在原位），
  并执行 `publish_ios_2117.py rollback`。
