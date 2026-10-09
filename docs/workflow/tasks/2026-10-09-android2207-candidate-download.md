# Android2207测试候选官网入口

用户明确要求：“请你在官网的download页增加测试候选包的下载入口，方便我进行下载”。关联[候选打包任务](2026-10-09-android2207-fix-candidate.md)与[原修复计划](../../superpowers/plans/2026-10-08-android2205-empty-room-investigation.md)。本次授权是独立测试下载，不是正式版/全量弹窗发布。

所有权：primary `frontend/download.html`、本任务文档、`docs/verification/artifacts/2026-10-09/android2207-candidate-download/`。primary无Git/.codegraph；初始本地页面与实时生产字节一致。准备方式仅插入独立Android候选section，删除该BLOCK后与原页面完全一致，不触碰正式Android2206/iOS2205/自动下载/业务JS。

| ID | 要求 | 当前证据 |
| --- | --- | --- |
| ENTRY | Android页签有明确测试候选下载、ARM64/版本及覆盖安装说明 | 页面before/after、3测试RED→GREEN，待上线 |
| ARTIFACT | 下载的是既有验包2207，保持固定签名 | 原28门禁复用；服务器上传/安装大小与SHA通过 |
| CDN | 候选经CloudFront，提供官网备用下载 | 新精确路径clone2206 behavior；保留旧10条/其他配置，待Deployed/HEAD |
| PRESERVE | 正式2206、iOS2205、设置/弹窗/别名和运行服务保留 | 快照已取得；上线后逐项读回，不能仅凭未写DB推定 |
| WEB | 公网HEAD与实际下载页入口可用 | 待上线小文件/浏览器验收；不回拉整包 |

实时基线02:57+08取得：正式Android2206/iOS2205，CloudFrontDeployed、10路径，35运行容器。源页面SHA `a72126b52191b1ef8f0ebf944ee4cc60541aa7a69367b8a5e69be10525915d3d`；插入后 `f9c2ff9c65d3e1cf472350483f064153ddf1c282f7630a713264c184d660e9fd`。新CloudFront路径 `downloads/ChatFlow-0.4.38-build2207-arm64-candidate.apk`，复用installer-hong-kong HTTPS源，不需要S3写入或桶策略变化。

候选83110942字节，SHA `ad8cc9d8826130449e21eb094b42728349bcf0590f021b71ac82e8c03fe0e324`。02:59:56–03:02:01+08上传至root0700暂存并核对；03:03:36独立inode复制、禁止替换的不可变安装通过。重传暂存不会截断已公开文件。

测试：最初缺模块collection失败exit2仅准备阶段；补行为stub后3项真实RED/exit1；实现后3PASS/0.11s。当前下载网络/重定向/正式发布投影Node51PASS/exit0。旧home-ios测试首轮50PASS/1FAIL，硬编码2194而生产已为2205；原始页面实跑基线仍1FAIL，候选页面已还原。保留日志，不把这一历史失败归因候选或宣称整套全绿。未变移动源码、安装包及服务代码不重复构建；完整verify缺.env这一既有环境缺口保留，运行适用下载门禁。

范围符合性：父代理确认单候选section/单精确CDN路径/既有资源与平台配置均保持；独立质量审查待结果。生产顺序：完整性安装→CDN ETag CAS及Deployed/HEAD→0700原页备份+SHA CAS原子换页→逐项后验。回退只在after SHA仍匹配时恢复本任务私有备份页面；候选文件不覆盖旧包，CDN删除仅本任务路径且保持其他实时配置。当前尚未换页。

下一步骤：审查完成后应用CloudFront路径，检查实际HEAD，换下载页并读回各平台设置/运行基线。实际手机安装和空列表故障验收仍由候选任务跟踪，官网入口成功不等于设备问题已验证解决。

## 发布闭合：2026-10-09 03:10+08

ENTRY/ARTIFACT/CDN/PRESERVE/WEB均通过。03:07:11+08新CloudFront精确路径提交，03:07:49状态Deployed；旧10路径及其他配置不变（现在11路径），桶策略未改。03:08:16经过实际CDN HEAD200/83110942/MIME校验与页面SHA CAS后原子换页，服务器0700原页备份位于`/opt/starchat/releases/android2207-candidate-download-20261009/download.before.html`；SG旧CF配置位于`/home/ec2-user/starchat-android2207-candidate-download-20261009/cloud-before.json`。

独立QUALITY/SECURITY PASS：精确新增section、候选单路径、HTTPS GET/HEAD、不可变文件/独立inode及CAS/备份接受；不代表手机故障已经解决。父代理规格符合性核对先完成。

03:08:24后验PASS：Android/iOS十个设置、schema、正式release JSON/旧APK/别名、其余静态文件和全部35容器身份/启动时刻/restart均与本次实时基线一致；CloudFront配置等于准备稿且Deployed，桶策略不变。工作站经本任务jumper SOCKS且保留TLS验证完成6项检查：候选CDN/官网备用与正式latest HEAD200/正确大小，官网页面SHA匹配、正式registry/iOS清单SHA保持。没有公网回拉完整APK。`https-result.json`/hk-after.json/sg-after.json及各receipt保存实际退出码与时间。

浏览器CUA打开官方入口尝试30s超时并重置kernel，未宣称取得截图/浏览器点击验收；公网HTML精确匹配与链接/原下载回归已验证。备用HEAD首次本地ad-hoc helper缺__file__失败未接触生产，改用明确direct-head模式后成功。临时SOCKS工具会话已Ctrl-C结束，18967无监听；所有发布/检查命令结束，没有留下临时连接。

实际入口：https://www.liuhetong888.com/download?platform=android#android-test-candidate
候选CDN：https://d12fjr06o6tga5.cloudfront.net/downloads/ChatFlow-0.4.38-build2207-arm64-candidate.apk
备用：https://www.liuhetong888.com/downloads/ChatFlow-0.4.38-build2207-arm64-candidate.apk

仅测试入口分发完成，正式更新弹窗仍2206；实际手机覆盖安装/空列表和入房恢复仍由修复候选任务跟踪。回退页面必须核对当前SHA仍为f9c2ff9c…660e9fd再恢复私有原页；若后来修改，先重读，不能覆盖新内容。CDN撤销仅移除本任务candidate精确路径，读实时配置后CAS，保留其他路径/桶策略和不可变包。
