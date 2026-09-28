# iOS 0.4.20（2189）新团队 IPA 直接分发

## 授权与范围

用户提供 `C:/Users/Administrator/Downloads/畅聊 ChatFlow (13).ipa`，选择仅更新新用户下载与 OTA 安装入口，不向已经安装同 build `2189` 的用户弹出新版提示。在获知签名团队 `ZXB3TS7QD4`→`A9HAF6NT6S`、新团队不能读取旧 Keychain 访问组、旧聊天连续性没有验证后，用户明确要求“只发布新团队的，直接替换”。旧团队已不可用，用户无外部保存的 Matrix 恢复密钥；至少一台旧签名 iPhone 仍能读取原聊天。

## 冻结包与生产切换

| 项目 | 结果 |
| --- | --- |
| IPA | `0.4.20/2189`，Bundle `com.liuhetong.liuhetongMobile`，61,871,675 字节，SHA256 `a2f8a145c5819ac6fc5488ad19f1c526e60c7fe2a0e6e699109f8520d930a9c0` |
| 当前不可变 URL | `https://www.liuhetong888.com/downloads/ios/ChatFlow-0.4.20-2189-enterprise-a2f8a145.ipa` |
| 旧不可变包 | `ChatFlow-0.4.20-2189-enterprise-6afd6827.ipa` 保留并可下载 |
| OTA manifest | SHA256 `32d7b1f8835f834bbdb2112caa5a5ccaafc7f34a9f0c8ed311d39c6bd6b2247b`，Bundle 与 build 正确，指向新不可变 URL |
| 官网 | `/download` 的 OTA 按钮仍指 HTTPS manifest，电脑端 IPA 直链指新包；最终 HTML SHA256 `4488a024ae32c4ca1b475b4d1baf104ac276966a64fe8df66e5c12756543d984` |
| 官网脚本 | `/src/download-redirect.js?v=20260928-ios13` SHA256 `a8f27e541081ae79c242dbccd075e780de7030cccf8c0d55c68dd5e7df5ac827`；iOS `install=1` 停在警示页，Android 自动下载保持 |
| 官网样式 | `/src/styles/download.css?v=20260928-ios13` SHA256 `0fd42fb351ae1406aad4df2406b1a0bdc2c17f47e89a0102669218c697b58ae5` |
| 设置与弹窗 | iOS `0.4.20/2189` 等十键设置前后相同，0 新设置审计行；同 build 不触发已安装 2189 用户的新版本弹窗 |

2026-09-28 18:02:38–18:02:40 +08，冻结的主目录 `scripts/release_metadata.py`（SHA `e555035a…357`）与 `release_settings.py`（SHA `57115372…7da`）执行单平台发布，返回 `PUBLISH_PASS`。先上传新不可变 IPA 并核对 SHA/长度及公网 HEAD，再切 OTA manifest 与网站。发布备份在 `/opt/starchat/docs/verification/artifacts/2026-09-28/ios13-direct-2189-a2f8a145-r1/`，目录模式 0700；设置发布前后快照逐键相同。

首次网页仍含对旧签名版本“直接覆盖以保留聊天记录”的不实提示。18:06 +08 左右先以 SHA CAS 更正文案；随后测试先红后绿，将新团队警示移到安装按钮上方，改用显著的语义颜色、边框与粗体，并用 `aria-describedby` 关联安装按钮。第一次静态修正后的页面/CSS SHA 为 `625b67f1…d152` / `7194cf91…9110`。

质量复核又发现生产 iOS 更新设置仍使用 `/download?platform=ios&install=1`，旧页面脚本会立即打开系统 OTA，绕过用户阅读警示。先用测试复现一次自动跳转，再改为 iOS 仅显示“请先阅读”提示，必须由用户点击 OTA 按钮才能安装；Android 自动测速与下载保持。HTML 的脚本 URL 增加新版本查询参数，确保旧 JS 缓存不继续自动跳转。此次三文件静态修正与发布器共用 `/opt/starchat/.release-metadata.lock`，逐一校验旧、新 SHA，先写 JS/CSS 后写 HTML，失败时仅在新哈希仍一致时从备份回滚。切换前 HTML/JS/CSS 备份均为 0600，最终生产与公网严格 TLS GET 的 SHA 等于上表；`release_metadata.py check` 再次输出 `METADATA_CHECK_PASS (no binary download)`。全过程未修改版本设置，因此仍无新版弹窗。

## 检查与隔离

- 回传包内 518 个文件与原 `(12)` 包相比仅签名相关差异；20/20 Mach-O 静态 CMS 与 page 校验通过。签名 application-identifier/Bundle 差异仍存在；这不等于 iPhone 可安装。
- 新旧 IPA 严格 TLS HEAD 均为 200，新包 `Content-Length=61871675`；manifest 为 XML、`no-store`，Bundle/build/新 URL 经解析。官网、manifest、CSS 公网 GET 与宿主机 SHA 相同。
- Android `0.4.21/2190` 设置、香港直连与 CloudFront 两路 APK 均未变，双线路 HEAD 200；API、worker、PostgreSQL、gateway 容器身份与镜像未变，schema 仍为 `0091_moment_video_posters`。未授权更新 API 返回 401。
- `node --test frontend/tests/home-ios-download.test.mjs frontend/tests/download-redirect.test.mjs frontend/tests/download-network.test.mjs frontend/tests/download-network-selector.test.mjs`：48/48 通过；`npm test`：380/380 通过。页面警示位置和 iOS 自动跳转分别先因缺失预期行为失败，再转绿；发布器 Python 43 项沿用静态页面修正前已通过的同输入结果。`git diff --check` 对改动文件通过。
- 按根仓规则预检 Python 3.12.10、Node 22.22.2、脚本与磁盘后启动 `pwsh -NoProfile -File scripts/verify.ps1`。仓库策略、部署策略、模板、渲染、infra 788、Getui 28 和 Matrix bot 9 项通过；进入 Business API/worker 套件约 4% 时，依据[移动交付工作流](../runbooks/mobile-delivery-workflow.md)的变更影响与证据复用规则停止：本次只变更下载网页/JS/CSS，后端输入未变，已有后端总门禁的独立已知失败记录。该次总脚本退出 1（人为中断），**不宣称全仓门禁通过**；原始尾日志在 `artifacts/2026-09-28/ios13-distribution/verify.log`。另一次从旧工作树调用 Python 测试时路径不存在，退出 1 且 0 tests，未作为通过证据；发布器 43 项来自主目录先前同输入检查。
- 规格复审与随后独立质量/安全复核均通过：确认 iOS 手动安装、Android 自动下载、警示可访问性、脚本缓存刷新、发布锁、CAS 与备份。独立只读生产后验见[证据](artifacts/2026-09-28/ios13-distribution/postpublish-independent/report.md)。包体及签名见[静态报告](artifacts/2026-09-28/ios13-distribution/ipa-verification/report.md)。

## 未经真机证明的边界

尚无新团队 iPhone 覆盖安装、旧本机历史读取、APNs 或 Apple 企业证书即时信任的设备证据。旧、新 Team 的 Keychain 访问组不同，不能承诺旧加密会话连续；这项风险由用户明确接受后仅执行下载入口替换。旧签名设备若是唯一可读历史，应保留，不应用上线成功推断其可安全覆盖。新 profile 有效至 2027-01-15；旧 profile 2026-12-03 到期。

下一可执行步骤：收到新团队 iPhone 的安装、历史会话及推送测试反馈时，将每项结果补入本任务；无反馈时生产分发状态保持已完成，设备兼容性保持未验证。
