# 安装包S3/CDN网络择优分发任务

## 恢复入口

- 用户已授权接入S3/CDN，明确按实际网络而非地区；已回复“按自动测速方案实现（推荐）”及“已添加补充策略”。不重复询问设计/基础设施授权。
- [设计](../../superpowers/specs/2026-09-27-installer-s3-cdn-design.md)、[计划](../../superpowers/plans/2026-09-27-installer-s3-cdn.md)。
- worktree：C:/Users/Administrator/.codex/worktrees/installer-s3-cdn/StarChat；起始bccd9492af1636a18b24bfe39cc5a34eff5ff01e。独占installer-delivery、网络下载模块/专项tests、release_metadata增量及本任务文档/证据；保留主目录其他任务改动。
- 当前：私有S3/OAC/分发实际部署；2026-09-28约00:16+08测速页面与Android下载URL已切换，单URLaudit、45容器镜像/重启计数、schema0090及iOS2173不变。IAM初始化权限收紧候选已审查，用户已确认同名维护策略全文替换。
- 用户已确认CloudShell执行；新分发E30IR8IHK6PMXZ/d12fjr06o6tga5.cloudfront.net Deployed，经真实默认字段红绿严格归一化和完整配置核对。无需重跑创建。维护角色读RHP配置仍被拒，实际响应CORS已验证。
- 收尾核验：管理员已确认同名维护策略全文替换；STS身份匹配，IAM GetRolePolicy只读AccessDenied，未扩权或重试，不能称机器比对PolicyDocument。新分发GetConfig与安装包HeadObject checksum再次通过。
- 交接：所属源码与文档已回填主目录，保留其他任务修改；独立分支codex/installer-s3-cdn保存本任务。回填门禁前端45项、发布器43项均通过；提交身份见非Git source-integration.json。
- 下一步：收集运营商真机长下载反馈；不主动重复探针或改版本。
- [交付报告](../../verification/2026-09-28-installer-s3-cdn.md)。

## 验收台账

|ID|目标|当前证据/状态|
|---|---|---|
|CDN1|既有2188固定签名包入独立私有S3|完成：HEAD checksum/SHA/bytes/MIME/cache匹配，匿名HEAD403|
|CDN2|按实际网络选择可用且稳定较快线路|已上线；真实Chrome一次CDN首轮超时淘汰，香港两轮成功被选择；不按地区|
|CDN3|主源异常香港回退，网络失败备用链接|源站回退完整配置核对；实际浏览器超时选择香港、手动备用与取消测试通过，未主动制造S3生产故障|
|CDN4|不可变长期缓存、动态版本无长期缓存|S3/CDN一年immutable、Range206与先Miss后Hit、registry json/no-store通过|
|CDN5|更新弹窗/网页一致，iOS/ABI保持|仅URL一条审计，DB同事务CAS/读回，iOS/其他ABI原值，HK+SG线上门禁通过|
|CDN6|真实设备网络效果|尚无大陆/东南亚运营商或真机长下载测点；不称全球/全程最快|

## 实际资源与证据

- Android0.4.19/2188 ARM64：81,505,310bytes，SHA256 aa402236aa2dbf06c5322358c6f8ad66e50f06ab5487bc08871ae34934d5e220，固定签名75b31c66…，来源f433381a；复用交接，不新APK。
- 新桶starchat-installers-218022113852-sg、OAC E6P1PEF2BA7OK；实际对象downloads/ChatFlow-0.4.19-build2188-arm64.apk。四项PublicAccessBlock/SSE-S3/Versioning/BucketOwnerEnforced/TLS-only读回通过。
- [云准备报告](../../verification/artifacts/2026-09-27/installer-s3-cdn/cloud-stage/report.md)；AWS CLI2.33.15/正确维护角色，初始List拒绝已因用户附加策略解决。
- 既有E11LA69ZDOD790/d1303mvwdm1ddm.cloudfront.net/chat-flow-total资源不属于本任务，未修改/复用；媒体/Matrix/业务镜像/iOS不变。
- 当前策略不允许维护角色创建分发/RHP、自改IAM；管理员脚本只创建两种新资源，幂等身份/配置检查、私有保存、独立安全PASS。
- IAM55、生成器43、admin原32→真实默认字段增量63，根合计161；maintenance57+bootstrap55=112。selector22、bootstrap3红→18绿、来源约束1红→3绿；最终front339通过。源码现网2173回填后旧2144快照2fail→对真实2173更新后339绿，未改变现网iOS。
- 仓库/部署/模板/UI契约(32组件403屏)/JS语法/diff均exit0；最终mobile171通过/1跳过，发布器62通过/0skip含真实隔离PG16.9并发与同事务回滚；源页面回填后受影响发布器43再通过。
- 全verify脚本未重新运行：worktree无.env，render-only前置不足；不导入生产秘密。业务/Flutter未变输入复用既有记录，保留旧完整失败口径，不称本轮全verify exit0。

## 阶段计时

|阶段|开始+08|结束|分类|结果|
|---|---|---|---|---|
|调查|精确首次工具启动未知|2026-09-27 22:49前|主动/工具并行|发现初始CloudFront权限拒绝|
|云准备|2026-09-27 23:13:10|23:15:49|工具|新桶/OAC/上传/读回exit0|
|管理员脚本冻结验证|精确开始未知|23:30:24|工具/审查|32通过/10离线SDK形状，安全PASS|
|本地受影响门禁|2026-09-27 23:39附近|精确结束未知|工具并行|策略/模板/mobile/UI/JS通过|
|管理员创建等待|精确开始未知|用户确认已执行，精确结束未知|外部等待|新分发真实身份核验完成|
|SG CDN探针|2026-09-28 00:14:27|00:14:39|工具|HEAD/Range/CORS/cache通过|
|网页/URL切换|2026-09-28 00:16:08|约00:16:13|工具|PUBLISH_PASS exit0|
|Windows浏览器单次采样|见browser/result.json UTC时刻|同文件|工具|CDN超时淘汰、香港成功、0整包下载|
|IAM收紧等待|已发异步替换请求，精确开始未知|用户已确认已替换，精确结束未知|外部等待|下载服务独立已上线|

## 回退与边界

香港既有2188包仍有效，更新URL已指向测速下载页。静态/Settings持久0700备份与漂移保护；Settings仅URL同事务比较/审计。文件组与数据库不是一个事务；歧义结果以读回及审计恢复，不盲目重放。原生产媒体、财务、Matrix、iOS不改。AWS原始响应留SG0700目录，不复制凭据或敏感日志。Windows验证引号与API基址/前缀假设失误，以及SG检查器错误要求香港APK MIME，均已保留原失败并针对真实现网纠正；没有改既有服务MIME或完整回拉包。
