# 安装包S3/CDN网络择优分发执行计划

> 使用 subagent-driven-development；按独占文件执行，先规格审查再质量/安全审查。

**目标：** 复用已验证Android0.4.19/2188固定签名ARM64包，通过私有S3/CloudFront与香港直连两个入口，下载时按设备当前网络有限测速选择线路。用户已批准此方案，不按国家或地区分流。

**架构：** 独立installer桶、OAC、CloudFront全球POP；版本化APK长期缓存；www动态registry和下载页测速；更新设置仅更改Android URL。保留香港备用下载与iOS/其他ABI。

## Task 1：权限与隔离候选

- [x] 云身份/当前包只读预检；IAM补充策略55项红绿/独立审查，用户确认附加。
- [x] OAC/分发/CORS/桶策略生成器43项红绿、4操作SDK离线形状验证；不使用假ID部署。
- [x] 管理员CloudShell创建/重试脚本32项红绿、10项SDK形状、独立安全审查。维护角色不授予CreateDistribution/TagResource或IAM写权限。

## Task 2：实际云准备

- [x] 唯一新桶starchat-installers-218022113852-sg：四项PublicAccessBlock、SSE-S3、版本化、TLS-only、默认BucketOwnerEnforced读回通过。
- [x] 新OAC E6P1PEF2BA7OK always/sigv4；旧分发/OAC/媒体不变。
- [x] 2188源包SHA/bytes核对后条件上传不可变key，HEAD checksum/metadata读回；匿名S3 HEAD403。
- [x] 管理员执行已提供CloudShell ZIP，创建/复用精确配置的CORS策略和带Project标签分发；读取实际ID/ARN/domain。
- [x] 精确2188对象+单分发SourceArn的OAC授权，读回；分发Deployed。
- [x] 严格TLS HEAD、小Range/CORS/缓存命中及配置回退验证；不完整回拉APK。

## Task 3：网络测速与发布器

- [x] 双线路各2轮、每轮256KiB、同线路顺序/不同线路并行；失败淘汰、保守吞吐/TTFB比较、取消/备用、无位置或用户信息。
- [x] 动态registry固定版本/两确切URL、大小/格式限制、30秒内存复用、网络变化失效；缺浏览器能力直接保留原下载。
- [x] 真实红绿修复整体预算耗尽后仍探测的问题；来源约束测试只允许两个确切声明，不能抹除恶意主机前缀。
- [x] 发布器network_selection仅返回URL，写静态前验证版本/build未变；同事务Settings前态比较和审计，真实隔离PostgreSQL并发验证。
- [x] 最终规格→质量/安全审查关闭，受影响门禁/证据身份记录。

## Task 4：切入口

- [x] 重新读取现网容器/schema/平台设置/static SHA。使用现网页面和首页增量render，保留实际iOS2173文案，不部署旧模板。
- [x] 0700持久备份，先部署3项JS和动态registry/页面；可恢复漂移检查与旧包仍可用。
- [x] 公网小型门禁通过后，SettingService仅app_apk_url改为www Android下载页；读回/审计/并发漂移拒绝。
- [x] 双平台HTTPS/设置/旧客户端入口/手动备用/真实浏览器超时淘汰/线路选择验证；执行机CDN响应未完成，不称本浏览器CDN CORS通过。真实大陆/东南亚运营商缺测独立记录，有限样本不保证全程最快。
- [x] 准备精确资源ID的维护IAM收紧策略，撤销初始化创建权限由管理员执行；不自改IAM。

## Task 5：交接

- [x] 更新任务/报告/current-state；标明云准备、CDN可用、入口切换三种实际状态及下一步。
- [x] 回填仅所属源码/文档，保留主目录其他任务修改；不提交秘密、raw云日志或非Git证据。
