# Android 0.4.24+2193 更新弹窗发布核验

> 状态：服务端设置已发布并独立后验；真实已登录 Android 弹窗与已鉴权 API 投影尚未验证。

## 目标与已知基线

用户在正式 Android `0.4.24+2193` 上线后，明确要求发布新版本更新弹窗。2193 APK 与 Android 版本/build/网络择优下载 URL 已由[上一发布](2026-09-29-android-withdrawal-quote-policy-release.md)在 2026-09-29 21:27–21:39 +08:00 完成；本轮没有上传或重签 APK。执行前生产更新说明仍为旧文案，Android 最低支持 build 为 `3`，不强制旧版用户更新。本轮仅把 `app_update_notes` 改为：

> 修复 USDT 提现报价显示异常；优化聊天搜索、朋友圈视频与部分页面体验。

Android `app_latest_version=0.4.24`、`app_latest_build=2193`、`app_apk_url` 当前网络择优入口、`app_min_supported_build=3` 均保持原值；iOS 五项设置及 Business API 镜像/schema 保持原值。发布器在写入前实时重读十项设置并锁行核对，避免仅依赖上一任务的时间快照。

## 客户端与接口契约

- Android 2190 历史源码 commit `b9eca8a419614112b085439445b7fd031027a740` 已在登录后的 `AppHome` 初始化检查更新，回到前台时每 30 分钟补查；2193 构建未传 `LIUHETONG_IN_APP_UPDATE=false`，默认启用。[触发路径](../../apps/mobile_flutter/lib/app_home.dart)、[2193 构建参数](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/release/run-20260929-205721-2193/artifact.json)。
- 客户端请求 `/app-updates/latest?platform=android`，拒绝不匹配的平台响应；服务端需要登录，匿名 401 为预期，不能拿匿名请求证明弹窗投影。[客户端边界](../../apps/mobile_flutter/lib/core/business_api_client.dart)、[服务端契约](../../services/business-api/app/api/app_update.py)。
- 响应要求 `configured=true`、`latest_version=0.4.24`、`latest_build=2193`、`notes` 为本轮说明、`download_url` 为现有 Android 网络择优链接、`min_supported_build=3`。客户端优先语义版本比较，无法解析版本名时才比较 build；已安装 2190 应提示，已安装 2193 不应提示。[版本判定](../../apps/mobile_flutter/lib/features/update/app_update.dart)。
- `min_supported_build=3` 下，本轮是可跳过弹窗，有“更新”和“稍后再说”；后者只抑制同一 AppHome 会话再次提示相同 build，下次启动仍可提示。[弹窗实现](../../apps/mobile_flutter/lib/features/update/app_update_dialog.dart)。本轮不改客户端行为。

## 发布范围与门禁

| 门禁 | 预期/判据 | 状态与证据 |
| --- | --- | --- |
| 生产前态 | 实时读取 Android/iOS 十项设置、2193 URL、旧 notes、API 镜像/schema 与审计 trace；确认没有其他发布者后继变更 | 22:26:32 +08:00 只读预检 exit 0；冻结快照十键一致、trace 空、2193 包及静态 SHA 匹配 |
| 包与下载入口 | 复用上一任务固定证书与包 SHA `8ea9eafb95bcf07c5655266d3eb71766c5799ba364103b23004820f3cf4e6dec`、81,767,454 字节；当前链接 HEAD/大小通过，无需公网完整回拉验包 | 本轮服务器本地 SHA/大小、HK 与 CDN HEAD 200/81,767,454 字节及五项静态本地和公网 SHA 经发布器预检/执行核对；独立后验再次核对 |
| 设置写入 | 在独立的服务器私有 0700 备份目录保存前态；通过公开 `SettingService` 仅写 `app_update_notes`，非空唯一 trace；严格核验写入结果与恰好一条成功审计 | 22:26:52 +08:00 发布 exit 0；备份目录 0700、文件 0600，trace `android-popup-0.4.24-2193-20260929T142419Z`，独立现网审计恰好一条成功 |
| 平台隔离 | Android version/build/URL/min 与 iOS 五项设置逐项不变，API 镜像/schema 和静态资产无写入 | `result.json` 十键 delta 仅 Android notes；独立实时 SettingService 对照一致。API 镜像 `sha256:fadabb52cd61c078599ceda2544cea6f34dd85b0dbc0b6c5d276c5d3a96ab7dd`、schema `0092_admin_session_entry_mode`、restart 0；五项静态 SHA 不变 |
| 公网投影 | 严格 TLS 下 Android 已鉴权最新版本响应可解析，notes 与下载 URL 正确；匿名 401、下载页与 APK HEAD 通过；iOS 保持原投影 | 严格 TLS ready 200、匿名更新接口 401、下载页/registry/三 JS 200、HK/CDN APK HEAD 200；没有真实已鉴权会话，Android/iOS API 投影未直接验证，服务器十键已对照 |
| 真机体验 | 已安装 2190 的 Android 登录后出现可跳过 2193 弹窗，点“更新”到既有下载入口；已安装 2193 不重复提示 | 待真实设备反馈；服务端读回不能替代 |

本轮只有设置文案变化，按[轻量发布门禁](../runbooks/release-metadata.md)复用未变的 2193 APK 构建、源码测试、签名和分发证据。发布器缺失时专项 16 项预期失败；补上事务契约测试后第二轮 RED 为 4 failed/17 passed；实装后 `py -3.12 -m pytest -p no:cacheprovider tests/mobile/test_android_update_popup_notes.py tests/mobile/test_ios_update_popup_release.py -q --tb=short` 为 29 passed/exit 0，独立专项 24/24 通过，规格及质量安全审查无 P0–P2。测试原始输出留在本任务工具记录，未落盘，不虚构日志文件。更宽的 `test_release_metadata.py` 为 93/98 通过、5 项既存 iOS 渲染正则不匹配现行 `aria-describedby` 标记，未改相关实现，也不将其记成全通过。更新前已校验生产前态和发布锁/并发控制；更新后已核对设置、审计和实际路由。

## 执行记录

| 阶段 | 实际执行时间（+08:00） | 命令/输入身份 | 退出码与读回 | 证据路径 |
| --- | --- | --- | --- | --- |
| 只读现网前态 | 22:26:32 | `publish_android_update_popup_notes.py preflight --trace android-popup-0.4.24-2193-20260929T142419Z`；脚本 SHA256 `0476d72a1f791b61fa72eada0043b939a56e058feab12509570ef9d093e6a6b9` | exit 0、`ANDROID_2193_POPUP_PREFLIGHT_PASS`，APK SHA `8ea9eafb…e6dec`、version 0.4.24、build 2193 | [原始预检输出](artifacts/2026-09-29/android-2193-popup/preflight.out)、[冻结输入](artifacts/2026-09-29/android-2193-popup/release-input.json) |
| 私有备份与 notes 写入 | 22:26:52 | `publish_android_update_popup_notes.py execute --trace android-popup-0.4.24-2193-20260929T142419Z --backup /opt/starchat/docs/verification/artifacts/2026-09-29/android-2193-popup-20260929T142419Z`；宿主上传脚本 SHA 与源码相同 | exit 0、`ANDROID_2193_POPUP_PUBLISH_PASS`、audit_count 1、备份 mode 0700、文件 mode 0600 | [原始执行输出](artifacts/2026-09-29/android-2193-popup/execute.out)、服务器私有备份同上 |
| 发布后设置/审计对照 | 22:27–22:29 | 下载服务器 `before.json`/`result.json`；独立代理只读重新查实时十键与全类型 trace | `before.json` SHA256 `21b72c79b1729f6c22c02ea9da9a761fbf01bc71db2de0afe0742c80770b41de`、`result.json` SHA256 `a4ce36cdfa638c5a0989d40adc9dc8697ed973f8aa0eee55afb5df11ad6208d9`；十键仅 notes 变化、成功审计 1 条；独立实时读回一致 | [前态快照](artifacts/2026-09-29/android-2193-popup/before.json)、[结果快照](artifacts/2026-09-29/android-2193-popup/result.json) |
| 公网 HTTPS 与 Android/iOS 对照 | 约 22:29 | 独立生产只读严格 TLS ready/下载页/registry/三 JS、HK/CDN APK HEAD、匿名更新接口及 API 镜像/schema | ready 200、匿名 401、五项静态 GET 200 且 SHA 不变、两路 APK HEAD 200/81,767,454 字节；API healthy/restart 0；iOS 五项设置不变；已鉴权 API 响应未验 | 独立 `update_prod_audit` 复核，静态原 SHA 见[发布计划](../superpowers/plans/2026-09-29-android-2193-update-popup.md)和前一发布报告 |
| 真实 Android 弹窗与安装入口 | 待设备反馈 | 待补 | 未执行 | 待补 |

## 风险、回退与完成口径

更新配置只有读取、文案和审计写入，本轮不改变强制更新门槛、包签名或资金路径。更新接口需要已登录账号；服务端匿名 401 仅验证身份边界。登录前、网络失败和已按“稍后再说”的同一会话可能不显示弹窗；这些行为由现有客户端决定。

写入结果未知时先读设置现值和 trace 审计，不能盲目重试或回滚。只有现值仍精确等于本轮目标且没有后继变更时，才可在同一受控发布流程中审计化恢复原说明；原 2193 包和 URL 不回退。生产备份目录及前后 SHA 已记录，审计由 trace 唯一定位；不暴露用户资料或凭据。真实设备显示和下载交互仍是独立验收，不因设置读回成功而宣称完成。

关联[任务台账](../workflow/tasks/2026-09-29-android-2193-update-popup.md)。
