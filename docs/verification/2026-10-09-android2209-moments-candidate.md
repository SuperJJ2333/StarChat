# 2026-10-09 Android0.4.40+2209 官网测试候选与朋友圈闪照修复

用户明确授权更新官网测试包，朋友圈相册大图不需要闪照。已完成有界修复与测试渠道分发；没有正式弹窗升级，不把历史性能目标未达成写为全面通过。

## 使用入口
- [官网测试下载](https://www.liuhetong888.com/download?platform=android#android-test-candidate)
- [CloudFront安装包](https://d12fjr06o6tga5.cloudfront.net/downloads/ChatFlow-0.4.40-build2209-arm64-candidate.apk)
- [官网备用](https://www.liuhetong888.com/downloads/ChatFlow-0.4.40-build2209-arm64-candidate.apk)
- [本地成品](artifacts/2026-10-09/android2209-moments-candidate/delivery/ChatFlow-0.4.40-build2209-arm64-candidate.apk)

实际standard ARM64 release0.4.40+2209，73008417bytes（69.626MiB），SHA256887d92c1984b0281127d124fd091dcde75fecf4aec66e541d0a2d2b45241b462；固定证书75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff。较旧2207的83110942bytes减少约12.2%，同ARM64发布构建可比较；此前2208x64 debug未用于官网下载。

## 修复
朋友圈发帖与评论复用了聊天ImagePickerPage，而该选择器总提供onSendFlash；朋友圈却在返回时拒绝flash，造成无效操作曝光。新增默认true的allowFlash能力，两个朋友圈入口false，预览不给闪照callback；编辑/选择/原图与压缩原策略保持，聊天闪照true，选取/编辑仍返回flash:false，防御拒绝仍在。

真实Widget入口测试先见2FAIL（朋友圈找到flash）/聊天PASS，再3GREEN；平台mock仅图库权限/数据，未mock内部业务。独立SPEC→QUALITY 5source/lock hashes一致。最终共享5710PASS/9既有skip exit0，Appanalyze0；复合analyze exit3来自vendor51原有问题（同工具baseline52/new0），不能称vendor全绿。相邻初轮38PASS/1FAIL旧composer异步PathNotFound早于全量，取消诊断退出1均保留；最终单进程全量未复现，未因此改产品coordinator。Policy/deployment/template三PASS，fullverify缺.env未执行，不导入生产秘密。

## 构建及发布证据
工作树 C:/Users/Administrator/.codex/worktrees/android2205-sync-deadlock/StarChat，基线b09bf2f2加完整冻结WIP；1929inputs manifest11d1e00f537302cda8b673b7414989660183909a97fbd34fdd79b38b7eef0d01。正常pub.dev pubget固定lock；首ARM64run Gradle parent-null失败保留，单任务stacktrace诊断重编译success1m5s后固定参数新run-20261009-074600-candidate成功，根因未由失败堆栈进一步确定，不假称产品bug。最终28steps exit0、Apktool2.12.1完整重建/zipalign16KiB/固定签名/独立解包与DEX/资源/manifest语义/ABI/输入无漂移均PASS。

07:51+08取得实时基线，正式Android2206/iOS2205、CF11条路由；初始7:28快照也保留。7:42跳板banner超时保留，7:45Probe恢复。私有stage上传7:54:15完成，完整服务器SHA7:54:17通过；immutable separate inode安装7:55:26，备用HEAD通过。冻结14项artifact/page/config准备输入经SPEC→QUALITY PASS，不回拉整APK。

CF仅新增第12条精确候选路径到installer-hong-kong，保留旧11/其他config/桶策略；7:56:57 Deployed。页面仅替换唯一测试section，before f9c2ff9c65d3e1cf472350483f064153ddf1c282f7630a713264c184d660e9fd → after496d0f8e7b0186e64a5aa47f915908b65d126888eb913201ecb89a214197fc7d，7:57:20 CAS原子发布。页面3pytest通过、旧下载48Node通过；旧iOS硬编码2194断言在相同发布前生产字节上2PASS/1FAIL留档，iOS区域未改。

7:57:32后验PAGE_CDN_AND_OFFICIAL_IOS_SETTINGS_RUNTIME_PRESERVATION_PASS：正式两端10settings/schema/alias/oldartifact/其他静态与全部运行容器身份/restart/启动时刻保持，CF等于新稿、桶策略保持。7:58工作站经自有loopbackjumperSOCKS/TLS保留校验完成6checks：新包双路与正式alias HEAD200/大小/MIME，小文件页面SHA/正式registry/iOS清单SHA一致；完整公网包回拉0。临时18967隧道已关闭。

回退基线持久保存/opt/starchat/releases/android2209-moments-candidate-20261009/download.before.html与SG同任务私有cloud-before.json；回退必须live-after CAS，只撤本任务精确route/测试section，不覆盖后来更新，不删旧包。

## 明确限制/交接
真实手机安装及使用待用户测试。原大历史性能SPEC仍未全面达标：百万陌生ID首次准确查重约5sec、100rooms缓存预览约2.4sec；本次UI修复不消除该缺口。资源清理/后台维护/差分代码已包含，动态资源集及差分分发API本次未上线，动画请求未命中时静态回退；不是宣称手机已使用差分下载。正式Android0.4.37+2206/iOS0.4.36+2205及全量更新弹窗未改，模拟器.debug仍独立2208。

阶段实际时间与各命令receipt/source/quality/failure记录位于artifacts/2026-10-09/android2209-moments-candidate/。下一步接收测试候选手机反馈；旧大历史首轮准确查询/预览等待优化继续由maintenance任务跟踪，后续正式build须高于已分发测试2209。
