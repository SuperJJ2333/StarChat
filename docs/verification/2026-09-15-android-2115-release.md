# 2026-09-15 Android 0.3.90/2115 发布（更新弹窗上线）

## 范围

在 0.3.89/2111 基础上累积发布：闪照（阅后即焚）、转发异步化、启动加载优化、账单筛选对比度、
相册滑动多选与 9 张上限、大视频发送前体积预警、可拖动视频进度条、发送方视频本地回读、
emoji 草稿阻断进入修复、新的朋友打招呼消息居中等全部至 2026-09-15 的修复。

## 发布物

- 版本 0.3.90+2115（pubspec `ff545ca7`）；ARM64 正式包。
- 固定流程：`flutter build apk --release --flavor standard --target-platform android-arm64`
  + 三项 HTTPS dart-define → Apktool 2.12.1 重建 → zipalign 36.0.0 `-P 16 -f 4` →
  固定证书 `75b31c66…` 签名 → aapt 身份（versionCode 2115 / versionName 0.3.90 / arm64）
  与语义验证、发行门禁全部通过。
- SHA256：`88F58299E583B8B4330DED5261A6FD414FA66C346DCAD5AFB7763BE2EFC83DF6`（79,277,086 字节）。
- 上传：16MB 分块经跳板顺序上传，服务端合并 SHA256 与本地基线一致后
  `install -m 0644` 为 `/opt/starchat/frontend/downloads/ChatFlow-0.3.90-build2115-arm64.apk`；
  `latest-arm64.apk` 符号链接切换至 2115；2111 及更早包保留（回退路径）。

## 更新弹窗

- SettingService `set_many`（trace `0.3.90-2115-20260915`，5 条审计）：
  - latest_version 0.3.90 / latest_build 2115 / min_supported_build 3（沿用，无强制升级）
  - notes（≤255 字符）：闪照、会话进入与消息选择修复、滑动多选、进度条拖动、大视频预警
  - apk_url：`https://www.liuhetong888.com/downloads/ChatFlow-0.3.90-build2115-arm64.apk`
- inspect→apply 两段执行；iOS 行（app_ios_*，0.3.81/2085）核对未被改动。

## 公网验证（服务器 + 工作站 jumper SOCKS 双侧）

- `ChatFlow-0.3.90-build2115-arm64.apk`：206 + application/octet-stream（Range 探测）。
- `latest-arm64.apk`：206，指向 2115。
- 旧包 2111 仍 200（回退路径完好）。
- `GET /api/v1/app-updates/latest?platform=android` 未授权 401（路由存活）；
  授权投影读回 latest_build=2115、apk_url 正确。

## iOS

0.3.81/2085 维持不变；2115 待签 IPA 待用户企业签名回传后另行发布（独立事务）。
