# iOS 2194 新回签包分发

- 用户授权：2026-10-03 要求更新 iOS 新安装包分发，提供 `C:/Users/Administrator/Downloads/畅聊 ChatFlow (14) (1).ipa`。
- 状态：2026-10-03 15:59 +08 已完成分发和两侧公网核验；真机结果未提供。用户明确回复“接受，直接分发此包”，仅当前精确SHA例外成立。
- 负责人：主代理；根工作区 HEAD `9abe0520bb76d23538e06f96b5c5ed78f71108ef`。只拥有本任务记录及 `docs/verification/artifacts/2026-10-03/ios2194-d532f913-distribution/`。已有历史 artifact 删除、后台 WIP 和 current-state 变动保留。
- 下一步：用户在iPhone验收安装/登录/旧聊天/后台通知并将结果绑定最终SHA；不重复已完成分发。后续源码或站点部署须保留本任务回填的两个链接。

## 验收与证据

| ID | 预期 | 事实 |
| --- | --- | --- |
| I1 | 核对最终包和CI来源 | 0.4.25/2194，61,709,960 bytes，Bundle `com.liuhetong.liuhetongMobile`；最终 SHA `d532f913dde2f6e1346b16c2a84633ee6257400a799a898b10cd446d0bc07cda`；原始CI SHA `a2f7db096df422c87ab472869909a073c38c8144729b2d1d049e7f7cca3ab6d1`，从既有服务器私有 release 下载，SCP退出0 |
| I2 | 签名权益/代码检查 | 企业 Team `4Z6MTB864G`，App ID `4Z6MTB864G.com.cigna.mobile.IOHspark.enterprise`，Keychain `4Z6MTB864G.*` / `com.apple.token`；生产APNs、debug false、profile有效至2027-09-03T17:50:50 UTC；19个Mach-O CMS签名和代码页hash通过，但标准身份门禁退出1 |
| I3 | 比对非签名内容 | 对原始CI比对退出1；恰好三项：新增ATHelper.dylib、flag，Runner加载命令变化。报告 `payload-comparison.json`，不能复用旧SHA的批准 |
| I4 | 当前生产基线 | 2026-10-03 15:46 +08 SSH观察：iOS仍0.4.25/2194，最终包SHA552a07a4；Android0.4.27/2196、两端min3。完整设置见settings-before.json；API001ddf336b3b / Worker3efd5924f343。未部署服务 |
| I5 | 新包分发/公网/回退 | IOS_RESIGN_PUBLISH_PASS；工作站/服务器PUBLIC_CHECK_PASS，十键最终读回和真实endpoint平台投影通过。新包已公开，旧包保留 |
| I6 | 真机覆盖/登录/聊天/通知 | 未验证。新旧Team/App ID/Keychain不同，不宣称升级保留数据，不卸载用户App |

证据目录：`docs/verification/artifacts/2026-10-03/ios2194-d532f913-distribution/`。

`verify_ios_enterprise_ipa.py` 按新Team运行退出1：profile or signed application-identifier does not match bundle identity。只读专项检查沿用旧检查函数结构，以当前实际SHA、字节数、Team/App ID、profile/certificate hash检查，输出code-signature-inspection.json，退出0；authorization明确为pending。这不代表标准门禁通过或Apple证书链/真机验证通过。

比对命令：`python scripts/compare_ios_ipa_payload.py --candidate <本任务candidate.ipa> --final <用户IPA> --json-out <本任务payload-comparison.json>`，退出1。此次没有源码改动、移动构建或重复全业务门禁。

## 计时与恢复

- 预检开始精确时间未知，首次显式本地时间2026-10-03T15:46:03+08:00，结束约15:50 +08；不从文件mtime估算总时长。
- 服务器第一次读清单用了错误的 `downloads/manifest.plist` 路径，退出1；修正为 `downloads/ios/manifest.plist` 后成功。设置读取第一次错误地在业务容器内导入宿主release_metadata，退出1；改在宿主release目录调用其公开db_settings后成功。
- 当前仅一次原始CI包SCP下载，已结束；没有创建隧道、没有最终IPA上传、没有生产写入，没有新增分支。
- 用户已看到具体待确认项。依据 `docs/runbooks/release-metadata.md`：2194旧例外限定精确SHA552a07a4；后续包重新取得身份、差异与授权证据。新团队升级兼容性尚未知，不能把本次普通发布请求或历史批准写成接受当前例外。

## 最终分发结果

- 当前包精确授权：用户对本轮问题回复“接受，直接分发此包”，问题明确披露同版本、新Team/App ID/Keychain、未验证覆盖保留及三项注入。不是通用豁免。
- [本次批准计划](../../superpowers/plans/2026-10-03-ios2194-resigned-distribution.md)。安装入口 https://www.liuhetong888.com/download?platform=ios&install=1 。最终不可变IPA `https://www.liuhetong888.com/downloads/ios/ChatFlow-0.4.25-2194-enterprise-d532f913.ipa`。
- 私有上传 `/opt/starchat/releases/ios2194-d532f913-20261003/`；0700备份 `/opt/starchat/docs/verification/artifacts/2026-10-03/ios2194-d532f913-publish/`，含完整release授权、before十键、三静态前态、result和双SHA比对，作为本次文件分发审计与回退记录。无设置变化，不产生虚假的SettingService变更审计。
- 同版本仅切download.html的电脑IPA链接和manifest的IPA URL；homepage逐字节保留，Android所有链接、包、注册表与十键保持。iOS应用内检查仍为2194，已在2194的客户端不会凭同build收到新的版本弹窗；安装页可主动安装新回签包。
- publisher.py专项：RED5项中3项因同build常规拒绝而失败；精确旧manifest/新包特批限制实现后GREEN5/5，0.055s。前端6项RED4pass/2fail→GREEN6/6，105ms；完整519/519，10.262s。所有真实退出码记录。初始两次依赖/缺文件失败未伪作行为RED证据。
- 本地和服务器都重验19代码签名、页hash和三项真实差异。标准身份/纯重签门禁失败保持。没有修改通用验包器、伪造真机记录、提高build或部署业务容器。当前API/Worker身份仍001ddf336b3b / 3efd5924f343。
- 工作站临时jumper SOCKS只绑定127.0.0.1:18946，严格TLS；已于15:59后关闭并确认无监听。所有上传、测试、发布和下载命令结束。
- 全仓verify预读发现会重新生成运行配置、运行未变更的服务/移动模块。本次依现行流程“未变工件发布只做签名/内容/分发检查”复用原构建门禁，不运行重复源构建或全业务验证；本轮发布器专项、全前端、两侧公开检查与实际平台endpoint门禁已执行。
- 规格复核先完成：当前精确包、同build、官网/OTA、平台隔离、旧包可回退和安装警示均有证据。随后质量/安全复核：共享锁、精确静态/十键前态、SHA及重验、不可变文件、0700备份、CAS恢复、无生产秘密/金融写；无阻断项。真机升级连续性仍未知，已告知并明确授权分发。

| 阶段 | 已记录时间 +08 | 结果 |
| --- | --- | --- |
| 首次时钟/预检 | 15:46:03→15:49:35 | 原始CI下载完成、身份/签名/比对/生产读完成 |
| 精确授权与发布器/测试 | 15:49之后→15:54:07附近 | 明确批准，专项5PASS、生成record、开始上传；精确交界未知 |
| 上传/前端与服务器预检 | 15:54附近→15:56附近 | 上传完成、519PASS、服务器预检PASS；阶段精确边界未知 |
| 发布/两侧公网/endpoint | 15:56附近→15:59:00 | PUBLISH_PASS、两侧PUBLIC_CHECK_PASS、十键/实际投影、0700与容器身份通过 |

可证实的观察区间15:46:03→15:59:00为12分57秒；开始早于首次显式clock，总墙钟未知。没有新移动构建等待。
