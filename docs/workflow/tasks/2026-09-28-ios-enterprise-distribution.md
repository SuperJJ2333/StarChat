# iOS 0.4.20/2189 企业包分发与更新提示

## 恢复入口与授权

- 用户回传 `C:/Users/Administrator/Downloads/畅聊 ChatFlow (12).ipa`，明确要求分发、更新，并在获知该签名渠道固定注入后再次要求直接发布。授权范围是该企业 IPA、iOS OTA 安装清单/页面和 iOS 更新设置。
- `docs/runbooks/app-release-deployment.md` 第 6 条要求 API 261f/0091 单独授权；本任务未发布该 API，也未执行迁移。原[朋友圈与房间任务](2026-09-28-ios-media-room-followup.md)的源码验收与本次分发证据分开记录。
- 执行工作树 `C:/Users/Administrator/.codex/worktrees/ios-media-room-followup/StarChat` 起始提交 `9aaf726f5baf3bd5bdd46b587d9171edc5a97696`；主目录承载其他任务的未提交修改，只回填本次静态源码、测试和记录。

## 验收台账

| ID | 目标 | 结论与证据 |
| --- | --- | --- |
| D01 | 回传 IPA 与 2189 候选及既有企业签名渠道相符 | PASS。版本 `0.4.20/2189`、Bundle `com.liuhetong.liuhetongMobile`；20/20 Mach-O 代码页哈希和 CMS 签名通过。原候选的 501 个普通文件不变，两动态库的文件段与已发 2120 相同。见[IPA 报告](../../verification/artifacts/2026-09-28/ios-enterprise-distribution/ipa-verification/report.md)。 |
| D02 | 不可变 IPA 经本地/服务器 SHA 和长度守卫可访问，旧包保留 | PASS。新包 `61,871,956` 字节，SHA256 `6afd6827b5d8bbef84b7384a59a97aa52e03fde5a4825d9ec684972eeb51b51f`；服务器独立读回完整文件同值（[收据](../../verification/artifacts/2026-09-28/ios-enterprise-distribution/server-ipa-sha256.txt)），独占硬链接发布。新旧 HTTPS HEAD 均 200；旧 2173 包保留。 |
| D03 | iOS OTA manifest、下载页、首页版本/电脑 IPA 更新 | PASS。发布器输出与生产三项静态 SHA 一致，清单 URL/Bundle/build 正确；独立公网 TLS 检查通过。 |
| D04 | iOS 更新设置和审计，Android/min/notes 不变 | PASS。13:18:26+08 发布审计 3 条 SUCCESS；iOS version/build `0.4.20/2189`，URL 同值重写；Android `0.4.19/2188` 和最低版本/说明均不变。 |
| D05 | HTTPS/HEAD/XML/页面/设置读回/401/静态回填验证 | PASS。独立服务器和工作站两侧检查，SettingService 十键读回、匿名更新端点 401；没有已鉴权 HTTP 更新投影证据。主目录静态回填后 iOS 定向测试 2 PASS，Android 下载选择器测试 44 PASS。 |
| D06 | 真机覆盖安装、推送和本地历史连续性 | 待设备验收。Windows 静态验签和 HTTPS 检查无法证明 iPhone 实际安装、APNs 或 Keychain 连续性。 |

## 发布身份与回退

- 发布记录：[release.json](../../verification/artifacts/2026-09-28/ios-enterprise-distribution/release.json)，记录 SHA256 `823541ab028187ce85ce9df81b3e7dda3ae64da6f3860a6c05c6e4f932f34049`。
- 不可变包：`https://www.liuhetong888.com/downloads/ios/ChatFlow-0.4.20-2189-enterprise-6afd6827.ipa`；安装页：`https://www.liuhetong888.com/download?platform=ios&install=1`；OTA manifest：`https://www.liuhetong888.com/downloads/ios/manifest.plist`。
- 原候选 App Store 签名包 `61,246,031` 字节 / SHA256 `59fa118c8ec1890dd4f6fff15c97c9b6de7693d5bb4245619de874258ea0073e`。用户回传的企业包与其可执行文件段、普通资源逐项核对。渠道新增 `ATHelper.dylib`、`libutils.dylib` 和 `flag`；前两份被 Runner 加载，与此前发布渠道结构一致。签名 profile 与历史 2120 字节相同，截止 2026-12-03；既有 application-identifier/Bundle ID 差异继续作为真机安装风险记录。
- 发布器保存 0700 服务器静态备份，旧 IPA 保留。设置若需回退，先查当前值与审计，再按发布器回退流程操作，不盲目重放。API e304/worker a508/schema0090、容器身份与重启数均未变。

## 证据与执行门禁

- [独立 IPA 核验](../../verification/artifacts/2026-09-28/ios-enterprise-distribution/ipa-verification/report.md)、[生产前态](../../verification/artifacts/2026-09-28/ios-enterprise-distribution/preflight/report.md)、[生产后态](../../verification/artifacts/2026-09-28/ios-enterprise-distribution/preflight/postpublish/report.md)、[外网验收](../../verification/artifacts/2026-09-28/ios-enterprise-distribution/review/postpublish/report.md)。
- 精确发布脚本 SHA256：`release_metadata.py` `e555035a5dbd7011680065a10f293680ec552e8b820fca9f37359921f009a357`，`release_settings.py` `57115372317368a79d9fe697c0dcf9e136bafb7b83cfa37fbe23949b4bd3b7da`。本地聚焦 14 PASS/19 跳过；相同源 SHA 的真实 PostgreSQL16.9 隔离发布器 62 PASS/0 跳过复用[既有证据](../../verification/artifacts/2026-09-27/installer-s3-cdn/publisher-cas/report.md)。生产 prepare `PREPARED_BASELINE_PASS`、publish `PUBLISH_PASS`、独立 check `METADATA_CHECK_PASS`。实际已鉴权 HTTP 更新响应未探测，不与设置读回混同。
- 生产静态 SHA：`download.html` `e8784540dc4fa0cd9a22450c47570be0d9042d6f1e7f39e6ac0aae46101afac7`；`admin-home.js` `8d14d88d998ea2430373a57a5d82e4f3e4a6279726cf82913511aa854c40e557`；`manifest.plist` `f3db239fbde5bf375b1c475dd0634ef3604d9953b6c2caae8e39b73d6500c9df`。源码回填以这两项现网静态 SHA 为守卫；Android CDN/香港备用链接保持。

## 阶段计时与下一步

| 阶段 | 时间（+08） | 结果 |
| --- | --- | --- |
| 交接与只读预检 | 13:06 起；生产基线约 13:05–13:08 | iOS2173/Android2188、容器/schema 和可用空间核验；并行代理只读 |
| 包核验与候选准备 | 13:06–13:18 间 | 签名、历史渠道、逐条目核验；上传后服务器 SHA；render/prepare 守卫通过 |
| 生产切换 | 13:18:26 | 发布器 PASS；三项 iOS 设置审计成功，静态及清单原子更新 |
| 双侧验收 | 13:19–13:22 | 服务器设置/静态及工作站严格 TLS 验收 PASS；自有隧道关闭 |
| 源码回填 | 生产切换后 | iOS 定向测试 RED 2（旧版本）→静态回填→GREEN 2，Android 定向 44 PASS |

下一步：在企业签名可安装的 iPhone 上确认覆盖安装、更新弹窗、通知与旧会话连续性；若需要生产新朋友圈视频封面接口，取得 API261f/0091 的独立发布授权后再部署并验收。不要把本次静态签名/服务器结果称为设备验收。
