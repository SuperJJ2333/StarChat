# Android安装包S3/CDN网络择优分发

## 授权与目标

用户2026-09-27要求接入S3/CDN，随后明确纠正为“不是按地区，而是按照网络情况，选择网速最快，最稳定的节点”，并回复“按自动测速方案实现（推荐）”。此前地区分配目标被此条替代。沿用已批准的2026-09-23私有S3/OAC/CloudFront公开版本化安装包基础设施方案；有限测速行为已获批准。首批复用已发布0.4.19/2188 ARM64包，81,505,310bytes，SHA256 `aa402236aa2dbf06c5322358c6f8ad66e50f06ab5487bc08871ae34934d5e220`，固定签名交接证据保留。不重新构建、不改iOS或其他ABI版本。

## 网络选择（已批准）

下载页在用户设备上对CloudFront和现有香港直连各进行两轮有限Range请求，单次最多256KiB、超时2秒，总探测预算5秒/最多1MiB。只允许registry内当前同一版本APK的两个确切HTTPS地址，不带凭据；响应必须206且Content-Range/长度准确，否则该线路不参加选优。先排除失败/超时线路，再按两轮较慢一次吞吐选择最快的可用线路，首字节耗时用于同等吞吐时比较。全部测速失败时保留香港原入口，不锁住下载按钮。浏览器无CORS/Range支持则直接使用已验证备用地址，不以HEAD延迟作为吞吐证据。

CloudFront内部仍按网络延迟选择POP，但用户侧另比较实际CDN/香港下载速度和可靠性。不能直接强制指定CloudFront某一POP，也不以国家/城市/GPS判断速度。全球CloudFront不等同大陆本地CDN；真实运营商长下载稳定性仍需测点，有限样本只能选择此时测得的最快可用线路，不能保证全程绝对最快。

测速只在开始下载时运行，不在聊天/启动后台探测。结果短期复用且网络变化/旧结果失效后重测；不记录IP/账号/精确位置，不用历史地区列表强制分配。浏览器外部下载无法获知下载管理器的后续失败，因此页面保留明确“备用下载”入口；S3原站故障由CloudFront自动回香港。不能把这两种回退合称浏览器全程自动重试。

备选：仅CloudFront自动POP选择改动较少，但无法比较CDN和香港的实际吞吐；在App内部实现多线路完整下载/断点续传能进一步处理下载中失败，但需要新APK和安装流程验证。推荐先做网页有限测速，无需重打APK；后续根据真实反馈决定是否加入App内下载器。

## 隔离与配置

独立私有桶 `starchat-installers-218022113852-sg`，ap-southeast-1，仅版本化公开APK字节进入 `downloads/`。不修改既有starchat-media桶的策略、business/synapse对象、Matrix、金融或鉴权。开启SSE-S3、四项PublicAccessBlock、版本保留、TLS-only；CloudFront OAC always/sigv4只读downloads前缀，并限定本次分发SourceArn。禁止列桶公开、公开写入和复制媒体。

CloudFront采用AWS分配HTTPS域名，PriceClass_All支持全球自动POP选择；不改www/API/SG现有DNS，不购买RDS/NAT/额外节点。只允许GET/HEAD。默认不带cookie/query/用户header，不启用含IP访问日志。版本APK写入一年immutable缓存、正确APK MIME；latest/版本元数据不放入该长期缓存域。现有HTTP Range能力必须验证。

S3为主源，现有www香港不可变包为第二源，仅连接失败/500/502/503/504触发GET/HEAD原站切换，403/404不掩盖权限/缺件问题。源站回退不等于用户网络无法访问CDN时自动恢复：网站必须保留明确香港备用下载入口，旧不可变URL继续可用。CDN域故障时恢复既有设置URL与网页链接。

## 发布与验收

先核对当次APK/云身份/现网基线，准备限定补充IAM与隔离候选配置。用户已确认添加补充策略；维护角色可准备指定桶/OAC和读取分发，但不能创建CloudFront分发或跨域响应策略。这两项由管理员会话执行已审查的幂等脚本，不尝试绕过IAM或请求秘密。AWS部署、上传、网络验证完成后才切Android URL和网页入口。更新设置仅app_apk_url到既有www的Android下载页，按SettingService审计和同一数据库事务内的前态比较，核对版本/build仍是原2188，min/notes及iOS不变；客户端无需新APK。发布器只允许确切Android下载页，测速registry只允许已验证的一个确切CDN主机及版本路径，不能允许任意cloudfront.net或任意HTTPS URL。

验证：真实红绿、AWS配置语法、最小权限、无媒体开放、API旧端兼容、HEAD长度/MIME/HTTPS、有限Range/206、缓存命中、快但失败/慢但稳定/两条超时/CORS拒绝/网络变化/无缓存等受控测速、故障回退、两端隔离、备份/CAS恢复。遵循轻量门禁不完整回拉APK。真实大陆/东南亚测速为独立缺口，不以本机/SG探针冒充用户网络。先规格审查后安全审查；无权限/未部署明确报告，不声称完成。

## 官方依据

- [CloudFront按网络延迟选择POP](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/HowCloudFrontWorks.html)
- [S3 OAC隔离](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html)
- [源站故障回退](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/RequestAndResponseBehaviorOriginGroups.html)
- [CloudFront IAM动作/资源](https://docs.aws.amazon.com/service-authorization/latest/reference/list_cloudfront.html)
