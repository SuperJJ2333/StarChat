# Orbit 官网静态发布

## 恢复入口

- 用户授权：本会话审核 HTML DEMO 与图标后明确要求「请你部署上线」。发布已审核两页及资源，不发布 App 或业务服务。
- 批准范围及计划：[发布计划](../../superpowers/plans/2026-10-05-orbit-website-publication.md)。
- 状态：2026-10-05 22:27 +08 静态发布完成；22:35 +08 两侧 HTTPS、线上浏览器及受保护状态核对完成。
- 所有权：home.html、download.html、site/orbit-20261005-v1/、本任务限定测试、记录及 artifacts。原始图标、管理后台、安装包、manifest、十项更新设置、选择线路脚本及 nginx 保持。
- 工作目录：D:/pythonProject/outsource/StarChat；主目录已有其他任务改动，逐文件准备与发布，未提交/push 整个工作树。
- 下一步：用户访问真实手机浏览器验收美观与安装操作；后续按本次线上文件SHA冻结下一发布，保留回退备份。

## 验收台账

| ID | 要求 | 生产证据 |
| --- | --- | --- |
| P01 | 审核版首页、下载页、APP图标上线 | 官网 / 与 /download；10静态文件SHA匹配 |
| P02 | Three.js及移动布局 | 线上390/1440px WebGL ready、图标加载成功、无横向溢出、0 pageerror |
| P03 | 保留当前App分发 | Android0.4.33/2202、iOS0.4.25/2194；manifest、registry、三APK别名、十项设置逐项不变 |
| P04 | 下载功能正确 | Android选线/备用/架构入口，iOS OTA与电脑IPA、签名警示保留；platform=ios&install=1正常选择iOS且显式安装 |
| P05 | 安全发布与回退 | 共享锁、前态CAS、依赖先行、0700备份、公网失败恢复、保留后续漂移测试通过 |

## 版本、证据与阶段时间

- 官网静态资产版本：`site/orbit-20261005-v1/`，10文件。
- 测试：生产页RED2fail/1pass→GREEN3pass；前端532PASS；UI契约34components/535screens PASS；限定发布器6PASS；既有release.render两平台兼容PASS。
- 原始日志：`docs/verification/artifacts/2026-10-05/orbit-deploy/`，含前态、候选、publish/result、公网SHA/HEAD、线上手机截图。
- 22:14:09 +08：首次生产时钟；22:18:32：前态及发布器测试完成；22:21–22:25：正式入口适配、门禁、浏览器和上传；22:26:40→22:27:19：执行发布；22:30:56：工作站公网核验；22:35后：浏览器、后态、隧道关闭。精确分段主动/等待时长未知；首次显式时钟前的准备不编造计时。
- CDN / 选线脚本 / App settings 均未重新发布。现有Android2202注册表与旧2196测试断言冲突，本次按真实生产基线修正测试期望，不改变发布包。
- 首次只读release.render兼容检查缺CI来源字段而退出1，补入既有真实CI SHA后通过，未做包发布。后态脚本第一次将JSON decoder的结束索引误作文本而退出1，修正后全项PASS；生产状态无变化。

## 回退与边界

- 服务器私有候选：`/opt/starchat/releases/orbit-site-20261005-2214/`。
- 持久0700备份：`/opt/starchat/docs/verification/artifacts/2026-10-05/orbit-site-publish-2214/`，含before/home.html、before/download.html、record.json和result.json。
- 回退须取得 `.release-metadata.lock`，只在当前HTML仍等于本次record候选SHA时恢复before文件；存在后继漂移先重读，不能覆盖新部署。新增版本目录可保留，不影响旧页面。
- 未改API/Worker/Matrix镜像或gateway配置，不重启容器、不写设置和账本。公网HEAD不代表真机安装/签名/覆盖升级验收。
- 本任务loopback SOCKS18948已关闭；本地预览4186保留。无运行中构建或CI。
