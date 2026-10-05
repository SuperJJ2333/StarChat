# Android 2202发布与iOS原始IPA交接

Android 0.4.33+2202 已发布，更新配置、下载页面、不可变APK及CDN均读回通过。iOS同版本原始IPA已取回供用户企业重签，本次没有iOS分发或TestFlight上传。

## 成品与线上证据

- Android正式ARM64：82,193,438 bytes，SHA256 `0e5255a631ceb37c6556f08caf1b7199637d85c5ea6bd050c49cf6d2f8e642c2`；稳定单签75b31…，源码→Apktool2.12.1→zipalign16→签名及独立语义/native/ABI门禁通过。构建05:22:38–05:26:49+08。首次generated integration registrant残留失败及限定修复重试证据保留。
- [Android下载](https://www.liuhetong888.com/download?platform=android&install=1)。HK最终检查static/settings complete，latest-arm64指向2202，新旧APK服务端摘要一致；运行容器/镜像、其他ABI及网络静态保全。CloudFront新增精确路由，Deployed，ETag E1VC38T7YXB528，双路HEAD200及CDN CORS通过，bucket policy保持。
- 05:52:27+08发布trace `android-2202-20261005-055227`，最终15:20+08实际路由/十键读回、恰好3条Android设置审计通过。最低支持build3不变，iOS仍0.4.25+2194。弹窗服务配置已启用；本轮未声明真机弹窗实测。
- iOS原始IPA：61,622,830 bytes，SHA256 `e5ab6d45f5d007e10d32d79a34bfc90b3cb1ceed6b51df12ab4fbeff826d2810`；BundleID com.liuhetong.liuhetongMobile，0.4.33+2202。[原包](artifacts/2026-10-05/mobile-2202-release/ios-candidate/ChatFlow-0.4.33-build2202-enterprise-resign-candidate.ipa)。AppStore候选供企业重签，尚未企业签名或发布。
- CI [37235412773](https://github.com/SuperJJ2333/StarChat/actions/runs/37235412773) exact265a5027，两job SUCCESS，05:16–06:01+08。artifact11316735457 digest3c12450e…a7aa4与下载ZIP一致；IPA SHA与CI一致，strict signature/production APNs/iPad/SQLCipher load order及31native tests通过。实际原包身份15:21+08验证通过。首次取回TLS EOF保留，后续严格TLS重试成功，没有降低验证。

## 源码与验证

移动tree5cd2a854…与用户验收及b54全量5455PASS/9skip/analyze0完全一致，复用已完成检查，无重复移动构建。发布helpers 30offline PASS及当前独立PostgreSQL16.9六例PASS；先规格后质量审查见release-review.md。原生恢复18/26跨进程Keychain/SQLCipher证据保留，不作永不L04/L07保证。

仅回填下载页面/Android registry及3个契约测试。页面iOS既有live d532f913路径同步测试，线上iOS文件没有变更。保留预期RED及旧iOS fixture失败日志，最终focused8PASS、frontend522PASS/0FAIL/0SKIP。整库verify缺本地env未执行，未导入生产秘密。

## 恢复与保全

生产私有备份 `/opt/starchat/docs/verification/artifacts/2026-10-05/android-2202-20261005-055227`；未知DB结果禁止重放。旧2196不可变包与旧CDN路径保留。源静态不整目录覆盖主区WIP。

主区1372无关WIP按逐文件SHA保全；源回填与既有WIP交叉的下载页面单独保留原字节，Git HEAD同步发布元数据，工作区原有修改继续保留。集成收据见main-integration.json。用户回签IPA后另行验证最终签名/内容，本次原包交接到此。
