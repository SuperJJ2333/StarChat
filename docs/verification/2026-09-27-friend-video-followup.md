# 好友搜索、改号校验与视频预览交付

## 交付身份

- 设计和计划：`docs/superpowers/specs/2026-09-27-friend-video-followup-design.md`、`docs/superpowers/plans/2026-09-27-friend-video-followup.md`。
- 移动源码：`05a2d950047f96d128fc1115cb7db5bec39db017`；1753文件manifest SHA `f0663c0fa843ca778ef183bf308bbc0714ca8597268d2b02185ca391129fe597`。
- Debug：0.4.15/2184，`com.liuhetong.mobile.debug`，x86_64；最终APK SHA `e49ad21446b3bff8bdaef1a3dec5bb0329e01e5cc095996c857ba4d29d141ba9`，135196840字节。
- 稳定签名证书SHA：`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。源构建→Apktool 2.12.1标准DEX/资源/manifest重建→zipalign 36/P16→稳定签名→独立语义检查，18步骤全部退出0。
- 模拟器：emulator-5556，覆盖安装、启动退出0；设备APK SHA相同；firstInstallTime仍2026-09-26 04:06:20，lastUpdateTime2026-09-27 12:43:02。没有卸载、降级或清数据。
- 已发布服务：API `sha256:e880ec8ed2dd340f0421b66701b8f8c40350606c1ae3ab9603e2e52125baad1d`，schema0090扩展索引；14:08:27.971+08完成健康切换。worker固定15659d6c…保持。

## 行为与诊断

邮箱、手机号完整等值匹配；手机号保持phone_findable、共同10/小时限流、自己与双向拉黑过滤。认证POST请求体传q，避免把新手机号搜索放进URL。畅聊号候选长n∈[m,m+2]，前n−2位一致，末尾0–2位可省略或不同，完整号优先、最多20项；仅检索当前号。二维码只接受完整号精确匹配。新输入立即撤掉旧结果，迟到结果和账号epoch变化不污染新会话。

改号规则分层展示；离焦先做格式校验，再立即检查合法新号的可用性。保留6–20位/字母开头/允许数字下划线短横线/大小写同号/365天规则。跨账号写、重复检查、过期结果与USERNAME_TAKEN后的旧可用标记均有断言。

相册准备失败定位为页面和压缩流水线重复订阅同一个单订阅progress流，编码器调用前已抛错。预览改为借用原片优先、必要时回退既有压缩流程；发送限制和E2EE保持。视频页两个显式顶部胶囊及bare脚手架隐式胶囊已关闭；内嵌加载、错误与重试保留。退出/重试立即取消当前诊断trace，迟到结果仍清理，不删除借用原片。

保留6f全链路scope/SDK/SQL关联和regional增量，融合c936快速原生失败分类。现场receiver `client_diagnostics.py` SHA6033c300…契约保留；2184公共只读运行时快照证明build2184、enabled=true、36recent/1active。快照仅闭合元数据，无VM auth URI或用户内容。

## 验证与实际计时

证据目录：`docs/verification/artifacts/2026-09-27/friend-video-followup/`。

| 检查 | 真实结果 |
| --- | --- |
| scripts/verify.ps1 | 12:14:42.962→12:46:31.598，退出0；infra235、Getui28、Matrix Bot9、API/worker2908通过/92跳过、mobile boundary108通过/1跳过；AST271、单head0090/offline迁移、OpenAPI、Compose均PASS |
| Flutter analyze | 12:25:23.735→12:25:35.853，退出0 |
| Flutter full | 12:25:35.855→12:28:47.714，4734通过/9跳过/1失败，原退出1保留；唯一旧断言要求视频顶部离线胶囊，与本轮要求冲突 |
| 冲突断言收口 | 仅测试文件改变：图片离线提示保留；视频held加载/失败/真实再次加载/再次失败/无顶部胶囊，2PASS及analyze0。按变更影响复用上述全量实现证据，没有把原exit1改写成全量PASS |
| 核心专项 | 后端合并52、Contacts156、username9、transport/version/HTTP metrics22、diagnostics35通过；视频trace退出3RED→15PASS；既有视频发送/生命周期129与picker/performance37通过 |
| HTML/UI | 完整332PASS；之后ASCII非法尾部20PASS/1FAIL→21PASS增量闭环，原生实现未改；UI契约33组件/476屏PASS；视频9状态及12专项通过 |
| 独立复审 | backend、mobile增量、HTML及具体生产候选均按spec/domain→quality/security PASS，报告绑定实际源SHA和证据 |
| APK重建 | 12:37:40.637→12:41:40.210，18步骤退出0，冻结源前后无漂移 |
| 安装/启动 | 12:42:57.421→12:43:03.969，覆盖安装/启动退出0，设备哈希及首次安装时间一致 |
| 生产API/0090 | fresh备份2.775s，迁移4.493s，Compose仅API重建2.102s；14:08:27.971健康；发布/服务器verify/工作站TLS均退出0 |

全量脚本的Starlette TestClient/httpx、Getui Pydantic class-config弃用警告来自既有依赖；本轮未更换这些依赖。跳过的环境/平台集成夹具保留，新增搜索索引另用真实PG16.9在线/离线/恢复及16并发核验。依赖锁固定实际2183使用的52207159…，后续全部--no-pub。

HTML浏览器复核：4187添加朋友页的a1111144可出现a1111123，规则文字14/20并保持留白；改号页分层规则与右侧输入；相册失败重试进入合成视频播放控件，全屏黑底，无顶部提示。HTML使用自有合成媒体，不作为安装包原生播放证据。

## 服务候选、回退和授权

从当时live bb108b47派生，6冻结业务输入映射11目标路径，其余1057源/配置及receiver6033保持。实际生产/opt默认入口导入闭合和合成TCP六组PASS；不扩充既有默认site回退缺失依赖的路径。一致备份SHA6fe445d2…/27847798字节仅服务器0700目录保存；真实PG16恢复138表行数、Matrix身份/claims哈希在0090前后与两次默认启动后相同。

raw旧bb在DB0090时因未知revision退出255；旧bb+相同冻结0090持久只读bind已验证默认启动健康。回退不删除索引、不downgrade。旧API没有新版POST搜索，客户端新搜索须同步协调回退，旧客户端GET入口仍兼容。具体候选复审无开放问题；用户在call_10ikDzCzm5ns77ETyTIkHfFq明确批准API候选和0090。

实际发布fresh一致备份SHA `13b2b4a530a6654ccefb3c39b6c55d239076d00552f1c6d3086e3921e3f81bd7`、27945087字节、138表，仅服务器0700目录保存。初preflight因Docker Mounts数组顺序漂移误报而退出1，未迁移或切换；重复读取证明所有完整字段相同，修为按Destination排序后全字段比较，fresh preflight退出0。没有减少守卫字段，也没有改变业务源或冻结镜像。

生产0090有效、非唯一、非partial索引；实际/opt五个业务模块SHA及receiver6033保持，OpenAPI GET兼容/POST严格q2–320确认；API健康、0重启、新error/warning0。worker/PG身份、配置、mount/network与25其他容器保持。服务器及工作站各8个小JSON HTTPS探针均证书验证0，健康200、搜索GET/POST与既有账号/改号入口匿名401；没有以生产真实联系人、OTP或鉴权写验证。最终独立发布复核报告保存于reviews/。

发布后独立spec/domain→quality/security最终PASS、无开放发现；冻结release.json SHA2a6639f9…、final-facts0d831b0c…、workstation-tls86dd8593…，发布报告最终SHA2c0868a8…；临时SOCKS关闭。主目录移动1753文件行为一致：1086字节相同、664仅LF/CRLF、3仅声明/注释/widget参数间空行，无新增执行逻辑或字面量差异。原字节检查及仅行尾检查失败均保留；没有把这些差异批量覆盖回主目录。49个本任务回填文件保持审过的源身份，最终文档与索引保留并行任务。

## 剩余设备事实

三段自有样片已放入模拟器DCIM/StarChatVerification2184并逐SHA核对、发送扫描：H264/AAC、静音H264、实际display-matrix旋转90°。旧名h264-rotated及第一次metadata-only remux没有旋转side data，不计旋转覆盖。Windows原生CUA不可用，没有驱动已安装相册UI的现成隔离入口；不使用会卸载应用的flutter drive。安装包真实相册/朋友圈/房间视频播放仍需人工设备反馈，未声称三段已原生播放。

iOS0.4.7：详见[调查](2026-09-27-ios047-startup-investigation.md)。该文案是启动unknown分类兜底，不能证明锁机；覆盖更新且解锁/重试/重开均无恢复更指向持续读取或预检问题。2173包含既有L04/L07相关修复，阶段码不能锁定本次设备根因。未修改恢复/认证、清钥匙串、清数据库或重建Matrix身份。
