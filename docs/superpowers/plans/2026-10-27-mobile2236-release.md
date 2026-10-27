# Android 2236 弹窗发布与 iOS 企业签名交接

用户明确授权：将刚验证的冷启动发送修复推送为 Android 新版本更新弹窗，并交付 iOS IPA，由用户企业签名后回传再分发。沿既有批准发布流程执行，不额外设计业务功能。

## 范围与所有权

- 复用干净 maintenance-completion 工作树，基线1ea9f2c5，运行修复7b6a894b。新分支codex/ios-history-ipa-2236-20261027，正常推送此候选以启动已有unsigned iOS CI；不合并main、不强推或改写历史。
- 只修改pubspec.yaml、lib/core/app_config.dart和ios-enterprise-package.yml版本至0.4.67+2236；发布后回填实际Android下载静态文件。文档为本计划、对应task/report及current-state条目。其余业务代码、主工作区现存改动不动。
- Android standard/release/arm64/lib/main.dart，既有HTTPS配置与75b31固定签名，完整Apktool2.12.1重建和36.0.0对齐。更新最低支持build保持3，iOS五键及已发布文件保持。
- iOS完整生产插件、同源unsigned device IPA，不使用App Store签名候选；实际设备构建、Ruby hook与iOS26原生验证分别记录。用户回签前不分发，不用历史注入例外替代新包审查。

## 执行与门禁

1. 已读取工作流/状态、Git、远程refs与CI。线上新鲜基线：Android下载2235，设置2233，iOS2215，36容器；2236文件不存在，无运行中同版本CI。原始快照保存于本任务证据目录。
2. 成对升版并同步unsigned workflow，执行版本契约、版本运行测试、移动边界与analyze。按1721完整输入哈希比较复用上轮共享测试；仅版本对不同的部分单独补验。不将上轮Windows临时目录失败、.env总门禁或Ruby缺口伪装为通过。
3. 冻结/提交候选，普通推送专用分支启动已有iOS构建。Android本地恢复依赖/生成文件，冻结构建输入，完整源码构建/重建/签名/语义与资产门禁，保存每步计时。
4. 基于新鲜HK/SG快照准备唯一Android发布记录与payload：不可变APK、CDN精确路由、latest-arm64、下载静态、Android最新version/build/说明。保持入口URL及最低版本和iOS；下载registry2235与设置2233分别校验。新增发布适配先离线测试，规格审查之后质量/安全审查，未通过不得切换。
5. 经既有jumper传输、核对上传完整性；共享发布锁、前态CAS、私有备份、公开SettingService与审计完成Android发布。只读检查线上HEAD/小元数据、五项iOS设置与静态、容器身份、审计和回退文件，不公网回拉完整包。不将发布等同ARM64真机覆盖验收。
6. 取得iOS同源CI IPA、工具/插件/权限/存储/资源/版本身份及平台测试证据；交付明确“未签名，待企业重签”。保留原始SHA及签名前payload，真实原生失败如实记录与处置，不擅自关闭门禁。回签后另核对签名权益/非签名内容/真机保数据升级，再依用户授权分发。
7. 更新任务和current-state，交付Android弹窗结果、APK下载与iOS本地包路径、已知测试/设备缺口、签名交接说明。

证据仅存 D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-27/android-ios2236-release/。不导入生产秘密至本地.env，不修改服务镜像、数据库schema、资金或认证/E2EE规则。缺少签名或设备反馈仅阻塞相关验收项。
