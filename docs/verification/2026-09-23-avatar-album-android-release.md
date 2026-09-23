# 头像、统一相册与朋友圈视频：Android 0.4.6 / 2165

本记录对应用户五项修复、头像仅静态图澄清及合并 main / Android 更新授权。源码候选基线 `f6295a6c`，隔离目录 `.worktrees/avatar-album-release`。不发布 iOS，不修改 iOS 更新设置。

## 规格符合性审查

| 要求 | 实现与证据 | 仍需设备确认 |
|---|---|---|
| 我/个人信息头像缓存 | 统一为 ProfileRepository 预热使用的账户缓存身份；UserAvatar 可独立传 avatarCacheKey，不改变默认颜色种子；二维码入口同步 | 真实账号反复进入的体感 |
| 统一头像相册/裁剪 | 复用 ImagePickerPage 与 WeChatImageEditor；单选静态图，原始 GIF 头检测；avatarMode 固定正方形、SafeArea 内 X/确认、正确按缩放拖动映射导出 | iOS 点击范围未真机验证；本次不发 iOS |
| 公告解密重试 | SDK maybeAutoRequest 默认只查在线备份，补标准 Event.requestKey；保留原始密文、成员与发送者检查，按会话30秒去重、随后解密 | 需要持有密钥且在线的授权设备；永失密钥不能凭空恢复 |
| 朋友圈相册/视频 | 复用相册、播放器、播放仲裁与账户媒体缓存；MP4/QuickTime单个≤20MiB，总附件≤9；服务端校验容器、所有权、完成态、可见范围；旧客户端图片字段不混入视频 | 原生编码支持、真机播放/内存体验 |
| Git/Android | 全部分支归档、只保留main；ARM64正式包源码构建、常规重建、固定签名；只更新Android弹窗 | 发布和推送结果见后续段落 |

规格审查先于质量/安全复审，记录位于 `artifacts/2026-09-23/avatar-album-release/avatar-independent-review.md`、`moments-independent-review.md`。继承修改复审为 `../avatar-album/independent-integration-review.md`；两份原整合清单32/32源码/测试哈希一致。代码版本和未提交继承清单见 `avatar-album-release/inherited-main.json` / `frozen-source.json`。

## 质量与安全修正

独立复审后关闭：GIF经编辑变PNG绕过筛选；二维码缓存身份不一致；缩放/拖动裁剪映射偏差；非法草稿数组触发500；相册读取视频期间提前发布；无缩略图内存图片预览失败；清缓存后的旧代下载被复用；播放器重试未淘汰失败引用。上传/读取期间禁删附件，失败发布重试保持同幂等键。

视频沿用既有媒体鉴权与可见性，不提供任意外链抓取，不跟随重定向。客户端大小限制不替代服务端限制。公告没有把密钥或明文交给业务服务，也没有改变SDK授权分享策略。没有财务公式、钱包状态或认证权限变更。继承的Outbox schema2不支持任意旧版降级，不允许通过清空待发消息回退。

## 验证分层

- 头像/图库/裁剪183通过，公告SDK恢复44通过；真实SDK调用，密钥解密与网络参与者仍为测试替身。
- 朋友圈后端21通过；Flutter专项171通过及上传禁删delta1通过，analyze无问题。
- frontend 299通过；UI契约32组件/403屏。浏览器在本地8157检查头像裁剪X/完成与朋友圈视频屏，复用现有风格。
- 全量 `scripts/verify.ps1`、Flutter analyze/test及构建结果将在完成后追加，不能用专项计数替代。
- 实际Android/iOS双端视频和公告互发未测；没有500人容量结论。

## 生产范围与回退

朋友圈视频所需4个文件同时覆盖API/worker，其余生产源码及配置不动；数据库head保持 `0087_support_payout_workflow`，不执行新增生产迁移。先备份并在隔离PostgreSQL恢复验证既有数据身份。首版候选在复审草稿修正前构建，未发布；最终使用独立 `avatar-album-r2-20260923` 候选并重新验证。

兼容回退镜像保留视频读取/DTO分离，关闭新视频上传；不回退成把视频当图片的旧读取代码。备份/镜像/逐文件证明留服务器私有发布目录。移动包保持既有签名SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，不降低最低支持版本。

## 时序与下一步

22:03:57+08 候选隔离完成；22:34左右代码复审冻结，启动Flutter全量与Android构建。精确门禁时刻见 artifacts 的 `*-start/end.txt`。下一步：记录最终门禁与重建身份，发布必要服务端/Android工件及弹窗，回填main并推送，归档删除已合入分支引用。

## 已完成全量客户端门禁

Flutter analyze：0 issue，exit0；全量测试 **3971 passed**，exit0（04:05）。日志 `avatar-album-release/flutter-full.log` 与两个exit文件；上传禁删测试在全量启动后补充，仅以定向delta1通过作为该测试证据，不推定全量已采集它。`git diff --check`通过。pubspec.lock仅镜像URL改动已恢复，227项依赖版本/哈希/SDK约束逐项相同。

源码构建首轮遇已知 Flutter integration_test 开发插件误入正式Java注册表，保留失败日志。按现有发布运行手册限定删除唯一开发插件注册块后重试；未删除生产插件，也未把debug包冒充release包。最终结果待工件门禁写入。

后端完整门禁于22:20:10启动，之后独立复审仅在朋友圈 `service.py` 增加草稿list[str]输入校验；该最终文件由21项后端专项重新覆盖（含5项先失败用例），镜像r2使用最终哈希。完整门禁与这次delta构成最终验证链，不将运行中的旧进程冒充加载过修改后的模块。最终Flutter生产源码在全量analyze/test和构建前冻结，只有一项补充测试稍后加入。

## 首轮工件（已作废、未发布）与生产候选

- 正式ARM64工件：0.4.6 / 2165，80,718,878字节；SHA256 `ede52bf2b8d6c34aa8931f23d28a9ec114e98d55b5314ee2f88db3e085474240`。22:43:22+08工件门禁完成；BUILD_2165_PASS，进程exit0。
- Apktool重建修改6个DEX与resources；独立解码比较25,346个类语义一致，338项原生库/Flutter资源未变，manifest语义一致；zipalign/apksigner及正式包检查通过。服务器暂存上传SHA与本地一致，暂存不等于发布。
- 最终API镜像 `e15807b29bc1fef5281a61f3f01152c7c4d39bd2eaf8a9e69f1e4c166195928d`；worker `90696ffa848299cc157daba0a80b0d3ce26a2693c13f1d5b0138ac70c740f1bd`。每个镜像335份源码逐项匹配清单；数据库备份隔离恢复/既有行身份检查通过。
- 回退兼容镜像API/worker均实测拒绝新MP4/QuickTime上传（503），保留读取与DTO增量源码；`rollback-video-check.log`。
- 5个本地codex分支已归档bundle/差异/未追踪文件后删除引用，工作目录保持detached并保留文件。远程2个历史分支等待main推送后清理。

HTML demo页面：`http://127.0.0.1:8157/index.html?screen=profile-avatar-crop`、`http://127.0.0.1:8157/index.html?screen=moments-composer-video`、`http://127.0.0.1:8157/index.html?screen=moments-composer-video-too-large`。本地开发服务不属于生产发布内容。

## 完整门禁与版本补正

原始 `verify.ps1` 在后端 **2727 passed / 74 skipped** 后发现Flutter内部备用版本号仍为0.4.5/2164，边界门禁1失败，原进程exit1留存。修正仅 `AppConfig.appVersionName/appBuildNumber` 为0.4.6/2165。首轮APK虽通过结构/签名检查，但包含旧备用版本号，**作废且未发布**，不冒充最终包。

按mobile-delivery工作流的已完成门禁复用规则，复用不受版本常量影响的已通过后端/前置检查；从原脚本Flutter boundary段完整续跑，**108 passed / 1 skipped**，UI契约、import、AST、Alembic、OpenAPI、Compose均PASS，`verify-resume-exit.txt=exit=0`。这不是宣称最初完整脚本exit0。另跑Flutter更新流程18项全部通过。最终APK在独立 `android-final/` 重建，避免覆盖首轮失败证据。74+1个skip保留未验证口径。

最终工件位于 `avatar-album-release/android-final/`：0.4.6/2165，80,718,878字节；SHA256 **60826c925134fa5d07dcba6a4829d6a463ba9bbf37446650000d0855634d871e**，22:55:45+08完成。固定签名、正式包检查与独立重建比较再次全部通过。旧SHA `ede52bf...`仅保留作废首轮证据，不发布。

服务端r2已经切换并回读验证：API/worker各335源码身份一致、healthy、0次重启、0个新启动错误，schema0087及其余22容器不变。HTTPS官网/download为200；业务域 `https://liuhetong888.com/api/v1/app-updates/latest?platform=android` 未授权返回401 JSON，鉴权正常。www域是官网，不能把其SPA回退200当成业务API验证。

已知工具链提示：后端Starlette TestClient的httpx弃用提示、Gradle Flutter插件Kotlin迁移提示来自既有工具链，本次未升级依赖。它们不代表这些工具链已完成未来版本兼容性迁移。

## 发布验收

2026-09-23 22:58+08 Android发布成功：`android-publish.log`含UPLOAD_IDENTITY_PASS/PUBLISH_PASS/ANDROID_2165_PUBLISHED，exit0。不可变文件为 `https://www.liuhetong888.com/downloads/ChatFlow-0.4.6-build2165-arm64.apk`，latest-arm64别名同步；未改arm32/x86_64旧包。

SettingService回读Android 0.4.6/2165、minimum3、新更新说明及不可变APK URL；全部iOS设置逐键不变（当前生产0.3.102/2144）。Settings审计与原值备份位于服务器 `/opt/starchat/docs/verification/artifacts/2026-09-23/avatar-album-android-2165`，镜像/数据库备份位于私有r2发布目录。工作站经专属loopback SOCKS+jump验证HTTPS APK HEAD200、80,718,878字节，业务域未授权接口401 JSON；没有重复下载APK或假称设备安装已验证。

未做本轮真机安装/视频编解码、iOS平台验收、实际多设备公告密钥互发；这些不计入自动化通过。最后步骤为main回填/提交/推送及已归档远程分支清理，证据将记录在本任务git日志。
