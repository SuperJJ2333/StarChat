# Android2188 S3/CDN网络择优分发

## 实际交付

2026-09-28约00:16:08→00:16:13+08，已有Android0.4.19/2188 ARM64的下载入口上线。用户已批准S3/CDN及下载前自动测速，并完成补充策略和管理员CloudShell创建。无新APK构建或业务镜像发布。

- [正式下载页](https://www.liuhetong888.com/download?platform=android&install=1)：CDN与香港各两轮256KiB Range，失败线路淘汰，以较慢一轮吞吐择优；名义总预算5秒/最多请求1MiB，30秒内存复用、网络变化失效，保留香港备用。
- 私有桶starchat-installers-218022113852-sg，OAC E6P1PEF2BA7OK，分发E30IR8IHK6PMXZ/d12fjr06o6tga5.cloudfront.net，Deployed。精确2188对象与单SourceArn允许CloudFront只读，匿名S3 HEAD403。
- 包81,505,310bytes，SHA256 aa402236aa2dbf06c5322358c6f8ad66e50f06ab5487bc08871ae34934d5e220；沿用原fixed75b31c签名交接，不重复称本次机器验签。
- 只改变app_apk_url；一条Settings审计。版本/build/min/notes、iOS0.4.7/2173、其他ABI与latest别名保持。45容器image/restart和schema0090完整前后相等。

## 验证与实际限制

|证据|结果|
|---|---|
|S3上传及私有边界|条件写一次，完整SHA/bytes/HEAD checksum/metadata/配置读回通过|
|SG CDN|HEAD200/正确MIME/bytes；两次256KiB Range206、CORS正确，SIN2-P10先Miss后Hit；前缀SHA与已验证源一致|
|Windows真实浏览器一次|香港两轮成功，保守199531B/s；CDN首轮约2秒timeout后跳过第二轮，选香港。requested786432B/success524288B，完整下载0。CDN响应没完成，不能称本浏览器CDN CORS通过|
|前端|最终339通过；源码回填现网2173后旧2144快照2fail，更新真实快照后339通过，原失败保留|
|移动边界|完整受影响171通过/1跳过；源码页面回填后发布器43项增量通过|
|发布器/事务|62通过、0跳过，隔离PostgreSQL16.9证明并发set/set_many、漂移拒绝、设置/审计同回滚|
|云候选|bootstrap55、分发43、admin63，根合计161；维护策略57与bootstrap合计112；12项离线SDK形状|
|其他门禁|仓库/部署/模板/UI契约32组件403屏/JS语法/whitespace通过。完整verify.ps1未新跑：.env前置缺失，按不变业务/Flutter输入复用已有证据，不称全verify exit0|
|最终审查|独立规格→质量/安全PASS；实际live输入生成的页面/首页/registry与源逐字节对应，iOS区域保留|

有限样本只能比较这两条路线在当时的表现，不保证所有运营商或全程最快。执行机物理地区未核实，不代表用户Redmi或大陆/东南亚网络；attempts不是用户数。CDN原站500/502/503/504和连接故障回香港配置已核对，未主动制造S3生产故障。浏览器外部下载管理器后续失败不可自动观测，需使用页面备用下载。

维护角色读RHP配置AccessDenied一次，未扩权限；分发绑定与真实响应CORS已记录，不称维护角色完整读回RHP配置。收紧IAM已通过独立审查，用户管理员已确认同名StarChatInstallerDeliveryBootstrap全文替换；维护角色GetRolePolicy读回AccessDenied一次，不能称机器比对PolicyDocument。STS身份、新分发GetConfig和安装包HeadObject checksum再次通过，详见[只读收尾](artifacts/2026-09-27/installer-s3-cdn/iam-narrow-readback/report.md)。维护策略可改写指定桶policy、覆盖对象、更新指定分发，发布门禁仍需约束提交内容，策略不是permissions boundary。

## 回退与错误闭合

0700前态位于HK `/opt/starchat/docs/verification/artifacts/2026-09-27/installer-s3-cdn-publish-stage/baseline`；发布器备份位于同级installer-s3-cdn-publish-backup。网页逐文件原子替换与DB不是跨域事务。DB在同一事务内比较完整前态、只写URL/审计/完整读回；结果歧义先读回与审计，不盲目重放。旧香港不可变包仍可下载。

初始浏览器/API/后台代码不变。验证脚本曾出现Windows引号错误、误用api子域及漏/api前缀；已根据真实AppConfig/main路由纠正，最终匿名三投影HTTP401通过。这些是验证脚本问题，不归入旧2184的超时/网络错误统计。AWS真实返回新增默认字段先严格拒绝，依据真实投影及官方API核对后仅接受唯一Id/GETHEAD集合、S3 timeout30、gRPC false、SelectionCriteria default，所有引用与主次顺序仍严格匹配，红8fail→63绿。

## 恢复入口与证据

- [任务](../workflow/tasks/2026-09-27-installer-s3-cdn.md) / [计划](../superpowers/plans/2026-09-27-installer-s3-cdn.md)。
- 非Git证据：docs/verification/artifacts/2026-09-27/installer-s3-cdn/ 下的cloud-stage、cloud-final、browser、publisher-cas、review、publication-closure.json、release.json和operations.json。浏览器profile内部缓存/DB、AWS raw结果与私有服务器文件不提交或导出。
- 独立worktree C:/Users/Administrator/.codex/worktrees/installer-s3-cdn/StarChat，起始bccd9492。部署源metadata e555035a…9a357/helper57115372…b7da；运行JS b31975d5…fc2ca/4699ca1c…0302a/a4030bc4…b446。
- 云准备23:13:10→23:15:49；SG云响应验证00:14:27→00:14:39；网页/settings切换约00:16:08→00:16:13。首次启动、主动时间/外部等待的精确总量未知，不按并行步骤简单相加。

## 源码交接

仅本任务29项源文件与文档提交到独立codex/installer-s3-cdn分支，git apply --check后回填主目录；current-state仅新增本任务入口，保留其他任务尾部。主目录回填前端45项、发布器43项exit0。一次日志重定向因主目录证据子目录尚未创建失败，测试未执行；建立指定证据目录后上述实际测试通过，不能将首次工具exit0当测试通过。脱敏证据按明确白名单复制，排除浏览器profile、数据库、缓存、APK、AWS raw响应和含测试连接口令的红日志。提交身份和所属路径内容比对见非Gitsource-integration.json。
