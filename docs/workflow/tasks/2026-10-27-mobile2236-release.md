# Android 2236 发布与 iOS IPA 交接

## 恢复入口

- 用户授权：2026-10-27要求Android新版更新弹窗，以及同源iOS IPA由用户企业签名后回传再分发。
- [执行计划](../../superpowers/plans/2026-10-27-mobile2236-release.md)；工作树maintenance-completion，基线1ea9f2c5；分支codex/ios-history-ipa-2236-20261027。文件所有权见计划。
- 当前：新鲜线上/远程预检完成，准备版本0.4.67+2236。下一步版本门禁、冻结源码、启动iOS CI与Android构建。
- 不修改主树既有改动；不合并main、不强推。正常推送候选用于用户已授权的IPA构建。

## 验收台账

| ID | 要求 | 当前状态 |
| --- | --- | --- |
| S1 | 最新修复同源、递增版本、门禁证据 | 待版本补验；上轮输入与缺口参照冷启动源码报告 |
| A1 | ARM64正式APK、固定签名与重建 | 待构建 |
| A2 | 官网与Android更新弹窗、审计、iOS隔离 | 待新鲜基线发布；下载2235/设置2233，iOS2215，最低3 |
| I1 | iOS完整设备未签名IPA | 待同源CI |
| I2 | iOS平台验证/企业签名/真机 | CI待运行；用户签名与真机待后续，当前不分发 |

## 证据、时间与恢复

证据根D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-27/android-ios2236-release/。09:51UTC预检CI无进行中作业；HK/SG快照记录36容器、schema0095_wallet_source_alerts、设置与静态/CDN身份。准备过程精确起点未记录；后续构建、传输、发布按机器回执计时。

运行修复7b6a894b已安装Debug供用户测试；本轮只升级版本元数据。保留上轮完整Flutter6421PASS/9条件SKIP/1Windows清理失败及原样12PASS补跑；总verify缺.env与Ruby/iOS条件缺口不能写成通过。生产金融/认证/加密源码无变化。
