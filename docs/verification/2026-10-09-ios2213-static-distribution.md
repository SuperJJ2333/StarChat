# iOS0.4.44+2213：仅官网分发

2026-10-09 21:42:40+08发布成功，用户指定回签IPA37966033bytes（38.0MB），SHA256 `9e5d358224a3fba64c6c5008bb0d20bf026a3fa3705a158b476ab1eb99bc8a21`。用户最新要求仅官网渠道、不启用更新弹窗；沿用本会话此前指定包直接分发偏好。没有修改通用验证器或签名政策。

- [官网安装](https://www.liuhetong888.com/download?platform=ios&install=1)，[指定IPA](https://www.liuhetong888.com/downloads/ios/ChatFlow-0.4.44-2213-enterprise-9e5d3582.ipa)。仅更新下载页、首页iOS标签及OTA清单，旧IPA保留。上传全SHA/大小一致；公网HEAD200/37966033、三静态GET逐字节SHA、实际安装路由及itms-services入口通过。
- `STATIC_IOS_DISTRIBUTION_PASS`，Android/iOS共十项更新设置前后相等，全部容器ID/image保持。iOS应用内配置仍0.4.36+2205/min3，Android仍0.4.44+2213。未执行设置apply、审计写入、容器重启或迁移。
- 旧renderer真实RED日志、新发布器五项GREEN：版本渲染、Android保持、只读设置、精确备份、失败回退、静态及设置漂移拒绝；独立SPEC→QUALITY/security PASS。未修改移动源码，无需重复CI编译/原生门禁。官网相关五文件Node专项54/54通过；首次53/54因历史2205版本期待已过期，保留红日志并仅更新2213版本/精确文件名断言后转绿。
- 实际签名AppID `7XL5R8V6RC.com.qiming.newhqzl299` 与Bundle `com.liuhetong.liuhetongMobile` 不一致；严格身份和原包比较均FAIL，目录/可执行文件改名且新增dylib/资源。按用户指定精确文件分发，未声称常规纯重签、真机安装、升级保数据或Apple企业授权验证通过。诊断归一化包未公开。
- 共享发布锁、冻结三文件SHA/CAS、0700原件备份及仅撤销本次写入的回退保护。私有备份 `/opt/starchat/docs/verification/artifacts/2026-10-09/ios2213-9e5d3582-static`，发布receipt含前后hash、设置、容器身份。
- 本地download/manifest精确回填；admin-home线上基线与main除换行外还有既有提现cacheEpoch与旧iOS标签差异，因此仅更新本地iOS标签，保留main的鉴权代码。未将服务器旧业务代码覆盖main。

证据在 `docs/verification/artifacts/2026-10-09/ios2213-static/`：identity-preflight、actual-signed-entitlements、strict-check、payload-comparison、publisher-red、publisher-tests、review-static、upload-integrity、publish、result、public-verification、public-ipa-head及frontend-tests。发布命令约6.4秒；其余阶段完整wall timing未记录，不补造。

下一步：用户iPhone实际安装反馈；如需启用新版本弹窗，另按用户后续指令处理。
