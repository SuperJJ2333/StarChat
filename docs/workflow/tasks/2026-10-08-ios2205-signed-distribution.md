# iOS 2205 企业回签官网分发

- 用户授权：回传9w6mt9j32dyjldij_signed.ipa，要求部署官网iOS下载渠道。未授权更换为旧版本或自动启用更新弹窗。
- 本次检查时间：2026-10-08 18:50+08起；精确工具结束见artifacts/preflight-result.json。
- 领取范围：此任务、最终IPA检查证据及官网iOS分发；不覆盖其他产品WIP。遵循admin-production/mobile-delivery/release-metadata工作流，复用已完成2205构建。
- 状态：被回传包身份不匹配阻断。实际Info.plist为0.4.33+2202，目标0.4.36+2205。最终45,190,727字节，SHA256 e4be3942e5f6238e909ce938511d85259f0ebc2afd5e51b11f55ad3c71a6b45f。
- 企业Team7XL5R8V6RC、实际AppID7XL5R8V6RC.com.qiming.newhqzl299，与Bundle ID不同。原包比对失败，顶层App名也变更；不把本包视作2205纯回签。
- 证据目录：docs/verification/artifacts/2026-10-08/ios2205-signed-distribution，identity-preflight.json、ios-payload-comparison.json、strict-check.log及preflight-result.json。
- 未上传、未更改官网/清单/CDN/设置/弹窗。现有官网渠道保持当前生产状态（本轮未读取，不沿用历史快照断言线上版本）。
- 下一步：用户交回已交付ChatFlow-0.4.36-build2205-unsigned.ipa的企业签名产物；对该包重新检查身份/权益及非签名内容，然后准备有备份的官网渠道发布。
## 用户覆盖授权与实际分发完成

用户获知包内版本不一致后明确要求“不需要检查，请你直接分发该安装包”。该精确文件授权优先于常规回签/升级门禁，不改通用检查器或复用历史其他SHA例外。此次不重复签名验包，不宣称设备或签名安全通过。

按[精确静态计划](../../superpowers/plans/2026-10-08-ios2202-exact-static-distribution.md)执行。18:55+08服务器返回STATIC_IOS_DISTRIBUTION_PASS：官网IPA/OTA清单/download.html及首页iOS标签发布0.4.33+2202；实际45,190,727字节/SHA e4be3942e5f6238e909ce938511d85259f0ebc2afd5e51b11f55ad3c71a6b45f。传输SHA用于确认所分发即用户指定文件，不替代签名检查。

- 安装页：https://www.liuhetong888.com/download?platform=ios&install=1
- 直链：https://www.liuhetong888.com/downloads/ios/ChatFlow-0.4.33-2202-enterprise-e4be3942.ipa
- 私有备份：/opt/starchat/docs/verification/artifacts/2026-10-08/ios2202-e4be3942-static，0700；旧包和旧静态保留。无容器重建，十项应用设置前后完全一致；未启用更新弹窗。
- 服务器HTTPS HEAD/清单解析/MIME/no-store/页面标识通过；18:55:30+08工作站HEAD200、长度45190727。未公网回拉完整包。现有CloudFront iOS路径403，本次使用官网现有HTTPS渠道。
- 三份服务器静态快照SHA与result匹配，本地源码只同步iOS元数据，保留其他WIP；专项语法/渲染/Android保全及规格→质量自检通过。用户要求无需检查系签名/包来源门禁，不取消防止误覆盖和传输错误的发布保障。
- 打包新源码修复仍在2205候选，此次按明确授权发布旧2202，不将本包描述为包含2205修复。设备企业信任/安装/覆盖升级/登录历史保留仍未验证。
- 下一步：用户在iPhone Safari使用安装页；如反馈安装问题，再针对本次精确SHA调查。官网分发工作无剩余项。