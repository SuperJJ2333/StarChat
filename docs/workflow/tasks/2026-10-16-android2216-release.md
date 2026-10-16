# Android 0.4.47（2216）正式发布

**当前状态：完成。** 2026-10-16 11:04:15+08 PUBLISH_PASS，11:04:30路由/审计及公网后验PASS，11:06:29服务保持PASS。Android2216普通更新已启用；iOS2215/min3保持。下一步仅收集ARM64真机覆盖升级反馈及后续16KiB兼容专项，不重放本次发布。

## 恢复入口
- 用户明确要求“推送Android的新版本和更新弹窗”。授权普通更新，iOS和最低支持build保持；不部署业务服务。
- 工作树 im-reliability；源码544b61b6，文档HEAD35f59abb。Root拥有构建、最终门禁、发布和本记录；backend_review仅拥有android2216-release/publication准备目录，禁止远程写。
- 关联批准计划：../../superpowers/plans/2026-10-16-mobile-experience-2216.md；本次追加正式Android交付。
- 2026-10-16T10:33+08：读取当前发布流程，准备ARM64构建与当下生产只读基线。下一步构建、规格→质量独审、不可变包上传及CDN验证，再单平台事务更新与审计。

## 验收与证据
- 共享源码全量6038PASS/9SKIP/0FAIL和analyze/实际main模拟器修复证据复用super-emoji-autoplay同输入；新正式包重新走源码→Apktool2.12.1→zipalign36→固定75b31签名及语义/ABI/资产检查。
- 正式包已构建，尚未发布。证据目录docs/verification/artifacts/2026-10-16/android2216-release。
- verify.ps1缺本地.env；历史libcrypto16KiB风险和真机/ROM/弱网矩阵缺口保留，不把Debug模拟器当ARM64真机通过。
- 新任务备份路径、完整SHA、设置前后态和阶段时间待真实产出填写；任何不确定远程写先只读检查，禁止盲重放。

## 2026-10-16 10:45+08 构建完成
- 构建02:34:49.842Z–02:44:06.889Z（约557秒），session80045 exit0；20步骤全部0。源码APK ca150517…bcbf91；最终SHA db914f66229cffa79825954200845ac841fd10486c77fb8ecce94dbef7b41039，73,262,170字节。包com.liuhetong.mobile，arm64-v8a/nondebug，0.4.47+2216，75b31固定签名。
- 25,414类/168,863方法语义一致，所有原生库/资源字节源包→最终包一致。与2215相比13非应用原生库不变，仅libapp.so变化。共享6038PASS/9SKIP和实际main/native模拟器证据按输入闭包复用，gates收集exit0。
- native inspector最初传2215而工具固定要求2213，exit2无有效报告；使用真实2213基线重跑exit1并保留libcrypto16KiB已知风险。没有把该报告写成16KiB PASS。
- HK02:36:33Z/SG02:36:39Z新基线两端2215、min保持、schema0095、35容器；CF17/Deployed，2216目标不存在。独立发布工具专项35PASS，生产尚未写。
- 下一步：完成精确实包SPEC→QUALITY，冻结发布包并执行fresh preflight，上传不可变APK、CDN检查、Android三键事务审计与官网两文件切换。

## 2026-10-16 11:03+08 上传完成，CDN传播中
- 实包及发布包独立SPEC→QUALITY全部PASS；reviews/release-review.json绑定freeze5df015a6…d551a6、runtime7d781261…55479、operation experience-20261016-2216。
- 02:59:14Z runtime：fresh HK/SG基线精确一致后安装两端私有发布工具；无业务服务部署。
- 03:01:31Z upload五块73,262,170B；03:01:42Z assemble全SHA与本地相同；03:01:56Z新不可变文件落地，latest仍2215。
- 03:02:31Z CloudFront精确新增路由，ETag E138L1TOL8PIJT，状态InProgress；桶策略不变。下一步cdn-check确认Deployed+HEAD/CORS再hk-switch/publish/audit。弹窗尚未切换。
- 自建HTTPS复核SOCKS：PID337672/start03:01:11.7705246Z、127.0.0.1:43825；结束需仅关闭自建进程，见public-check/tunnel-start.json。

## 最终发布与交接
- 03:03:24Z CDN Deployed/HEAD200/CORS通过；03:03:44Z alias切换2216；03:04:15Z官网两文件与Android三键PUBLISH_PASS；03:04:30Z真实route+三审计回读PASS，同时工作站8请求/11断言PASS。
- 03:04:40Z自建SOCKS已关闭；本地四源文件回填按精确SHA完成，保留admin-home钱包会话保护；03:06:29Z35容器/schema/guards/依赖/旧APK保持、备份0700、十键后态PASS。
- 备份 `/opt/starchat/docs/verification/artifacts/2026-10-16/android2216-experience-20261016-2216`；审计trace同末级目录名。源码/包/审查/执行身份及限制见[最终报告](../../verification/2026-10-16-android2216-release.md)。不得把平台配置验收写成客户端真机可见弹窗实测。
- 无进行中的本任务进程、CI、隧道和映射。最初postflight动态old_artifact断言失误及显式旧包重检保留于报告，未触发任何回退或生产修复。
