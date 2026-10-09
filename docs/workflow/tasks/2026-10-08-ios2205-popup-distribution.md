# iOS 0.4.36+2205 官网分发与更新弹窗

## 授权与范围

用户回传C:/Users/Administrator/Downloads/Telegram Desktop/9w6mt9j32dyjldij_signed (1).ipa，明确要求分发、官网渠道更新、应用内弹窗启用。沿用同会话不重复签名/原包验包的偏好；按实际包内版本0.4.36+2205发布，不宣称签名/真机升级通过。[计划](../../superpowers/plans/2026-10-08-ios2205-popup-distribution.md)。任务 owns本计划/记录/索引段、唯一证据目录和官网iOS元数据。

## 完成状态与证据

- IOS_DISTRIBUTION_AND_POPUP_PASS；精确最终SHA256 a122af8389bcae5e25506b71e93181d6164e9007e8a859ed5f83a129c769a653，47,743,050字节。源码修复构建仍以原CI记录为依据，回签后设备安装未验证。
- 官网安装页：https://www.liuhetong888.com/download?platform=ios&install=1
- 官网IPA：https://www.liuhetong888.com/downloads/ios/ChatFlow-0.4.36-2205-enterprise-a122af83.ipa
- 官网安装清单、download.html、首页iOS版本标识均更新2205；源代码只回填iOS元数据，保留其他WIP。
- 公共SettingService事务CAS写iOS version/build/说明/HTTPS安装页URL；实际运行route投影ios configured=true/version0.4.36/build2205/minimum3/URL正确。Android0.4.35+2204与两端最低build3保持，容器id/image均保持；未创建外部授权会话或JWT。
- 唯一审计trace ios2205-a122af83-20261008-popup，4条setting SUCCESS，含下载URL同值审计。首轮检查预期3条误判，实际设置已提交；只读检查4条before/after/keys后闭合，未重放数据库写入。原失败日志保留。
- 服务器HTTPS HEAD与小型清单、官网标签/MIME/no-store通过；19:28:01+08工作站HEAD200/47743050。未公网回拉完整包。沿用现有官网HTTPS iOS渠道，未改CloudFront配置。
- 私有备份/opt/starchat/docs/verification/artifacts/2026-10-08/ios2205-a122af83-publish，0700，含三旧静态、before、popup-intent、result。旧IPA保留。不盲目回滚已提交设置，需依当前CAS基线经SettingService恢复。
- 证据：docs/verification/artifacts/2026-10-08/ios2205-a122af83-distribution；reviews、release-input、server-publish失败日志、outcome-inspection、final-readback、server-result、workstation-head及source-sync。

## 时间与下一步

19:21:28+08读取生产前态；后续工具准备、上传持续至19:26；19:26:51包落盘为观测时间而非工具起始。19:28:01公开HEAD通过，准确步骤持续时间未逐项采集，不伪造。无需重建IPA/Flutter测试；专项语法/渲染/Android保全和规格→质量自检通过，保留首轮审计误判及纠正。

发布范围完成。用户iPhone实际收到弹窗、企业信任、覆盖升级/旧登录历史及后台通知仍待设备反馈，不宣称已实测；弹窗为普通可跳过更新，最低版本未提高。后续设备反馈应绑定本次最终SHA。
