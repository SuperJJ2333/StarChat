# iOS 0.4.25（2194）企业包分发证据

2026-09-30 21:54 +08 生产发布成功；22:02:16 +08 工作站最终公开验收通过。用户对本次具体 SHA 的签名服务改动明确答复“确认，直接发布这个包”。[计划](../superpowers/plans/2026-09-30-ios2194-enterprise-distribution.md)与[任务](../workflow/tasks/2026-09-30-ios2194-distribution.md)保留授权和恢复入口。

## 精确发布身份

- [安装页](https://www.liuhetong888.com/download?platform=ios&install=1)，[不可变 IPA](https://www.liuhetong888.com/downloads/ios/ChatFlow-0.4.25-2194-enterprise-552a07a4.ipa)。最终包 61,709,705 bytes，SHA256 `552a07a491129f0dd61120eff54a293eb6c3a8b0a3b57ab9001a17c16eef13bc`，Bundle `com.liuhetong.liuhetongMobile`，0.4.25/2194。
- CI 原始候选 SHA256 `a2f7db096df422c87ab472869909a073c38c8144729b2d1d049e7f7cca3ab6d1`，61,363,376 bytes，冻结移动源码 `05c05793cf089312a0ae8001aeb742ad19e8ff95`，CI36712413903。此次未变更移动源码或重新构建。
- 企业 Team `A9HAF6NT6S`，已签/profile App ID `A9HAF6NT6S.com.cd-rail.zhct`，Keychain `A9HAF6NT6S.*`、`com.apple.token`；生产 APNs、get-task-allow=false、ProvisionsAllDevices=true，profile 有效至2027-01-15 09:41:06 UTC。
- profile SHA `4ff6a0ecb829d34c02e5d7c7f3c7c09eb52ffae4d5ea3ae037dd8a99b8a65be2` 与上一已发布新团队2189相同；签名证书 SHA `59feec8e1fb3cc8e62e7ffdc059fcb4ed2e19209e6b608da61d528b39d1be113` 与 profile 匹配。19个 Mach-O 主 CodeDirectory 页 hash 和 CMS 内容签名在本地、服务器均复核；Apple 设备信任和运行效果并非静态验签结论。

普通检查器因特殊 App ID 返回1，严格内容比对也返回1，真实差异恰为：新增 `Frameworks/AppRuntime/ATHelper.dylib`、新增 `flag`、Runner 的 CPU100000c 加载指令变化。当前包的双 SHA/三差异经用户单独批准；2189授权未直接复用。通用严格脚本未放宽，记录没有伪造普通门禁通过或真机升级证据。

## 发布与隔离

私有暂存 `/opt/starchat/releases/ios2194-552a07a4-20260930/`，0700备份 `/opt/starchat/docs/verification/artifacts/2026-09-30/ios2194-552a07a4-publish/`。发布器在共享锁下重检两个包、十键设置和三静态前态，落不可变IPA、原子更新三静态、公网小元数据检查、再次本地验包后才经 SettingService 十键事务 CAS 发布四个 iOS 设置。审计 trace `ios-2194-552a07a4-20260930T134418Z`，恰四条 SUCCESS、actor `ops-release-metadata`，before/after逐项核对。

| 设置 | 发布结果 |
| --- | --- |
| iOS版本/build | 0.4.25 / 2194 |
| iOS入口 | HTTPS安装页，platform=ios&install=1 |
| iOS更新说明 | 钱包申请提醒不再重复；充值页只显示最新订单；修复搜索好友备注、头像及聊天记录显示。 |
| Android全部五键 | 与完整前态一致，0.4.25 / 2194 |
| 两端最低支持build | 均保持3 |

现场直接调用生产容器内真实更新 endpoint（不生成 JWT、不开放认证绕过），两端返回 platform、版本、build、说明、各自安装入口均正确；公网实际 API 域名 `liuhetong888.com` 两端匿名401。官网位于 `www`，首次验证误用www/API返回网站200，纠正域名后通过，未误称匿名验收成功。

公开 HEAD 新IPA200/61,709,705bytes，旧2189 IPA200/61,871,675bytes，Android2194 APK200/81,767,454bytes；XML身份/URL/version、MIME application/xml、no-store、页面入口均通过，未公网回拉完整IPA。Android registry 与三段下载JS哈希完全保持。

| 静态 | 本次发布SHA256 |
| --- | --- |
| download.html | `f309c3fc5fb6fa59f74da217a645f32a173a50aea6938217cf18fb97b5fc78be` |
| iOS manifest.plist | `afbff72ccc5e9fe2c5f5688d74bb3ce109067f9d6f2852125b4ea084bdbbb669` |
| admin-home.js（发布时） | `2a53e0a08892760089ea60ce01816748c398421486228ef57dcbb03328135ee6` |

并行后台任务在21:56:40修改首页唯一一条 walletAccessPanel 资源版本号为 `20260930-payout-read-fix`；因此22:02观测首页 SHA为 `554fef70c9f2d2b253badcf922faf187458ee412616e50a448dd6e08511f229a`。逐字节差异只有该import，三处2194文案保持；未知漂移首次被正确拒绝，精确分析后保留并行改动。源码仅回填自己的iOS三个标签和下载页/清单，未把生产后台代码覆盖到main。

API `001ddf336b3b268b530bd9223d48cdb48ff3835ea674cbba245765905689b71c`、Worker `3efd5924f343d7e81056e014519a43f411b617747903e2f8e26b6281e00c43ea` 前后观察一致；本任务未部署容器或执行金融写入。

## 测试、审查与范围

Windows PowerShell7、Node22.22.2、Python3.11.11；服务器Python3.12.3。前端无第三方依赖锁，package.json SHA `24f569670f98549ab61a8f7eae18a1b6d5eb5fcce97e1b496e8ae2df6ba22fca`。发布器SHA `0b2ad8dfb499d7f492a93f78a6569c6ed2e813e1e52227005e2f8c64134a88c9`，精确包guard SHA `788bf5311dd3c21972ddef72ace8df933fc15388902d5bda7978446957ec0356`。

- 新发布器 RED：缺少实现模块导致 collection failure；GREEN：`python -m pytest .../test_publisher.py` exit0，6通过0.25s，覆盖公开门禁失败回退、设置漂移、静态漂移、错误例外、结果未知不重放及平台隔离。
- 页面 RED：两项2194元数据断言失败、四项通过，exit1；回填后 `node --test --test-reporter=spec tests/home-ios-download.test.mjs tests/download-published-2194.test.mjs` exit0，6通过98.90ms。
- `npm test` exit0，519通过、0失败/跳过，16,427.42ms。
- 服务器 preflight/publish exit0，`IOS_2194_PREFLIGHT_PASS`、`IOS_2194_PUBLISH_PASS`，服务器/工作站 `release_metadata.py check` exit0；最终 `finish_checks.py` exit0，公开哈希、Android隔离、401、HEAD和四审计通过。
- 独立规格复核后质量/安全复核无P0–P2。P3：测试替身未覆盖真实审计验证的异常分支，后续可补异常actor/before/count用例；本次生产四条实际审计额外逐项验证通过。
- 复用主任务冻结移动端CI/Flutter及业务门禁；本次仅发布同源回签包和静态元数据，不重复构建/全业务测试。未重新运行完整verify.ps1；此前隔离主任务运行受本地.env缺失阻断，不宣称全仓verify通过。

原始本地日志与JSON位于 `docs/verification/artifacts/2026-09-30/ios2194-distribution/`：`payload-comparison.json`、`exact-package-check.json`、`server-result.json`、`public-final.json`、`actual-route-projection.json`、发布器及前端红绿日志。服务器私有目录保留原始候选、回签包、执行脚本和备份。

真机覆盖安装、登录、旧历史/Keychain和后台提醒尚未收到结果，均不标为通过。保留既有显著签名警示及iOS明确点击安装行为。回退时必须先核对当前十键设置与审计，并对最新三个静态重新识别漂移；首页已被并行修改，不可盲目恢复整份旧首页。设置结果未知须先检查trace，不自动重放或静默回退。
