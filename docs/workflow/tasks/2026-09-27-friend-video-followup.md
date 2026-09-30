# 好友发现与视频反馈

## 恢复入口

- 用户授权：2026-09-27五项具体修改/调查，要求确保接入全链路卡顿诊断与性能监控；改号6–20/365天继续前轮已批准规则。既有Debug模拟器安装授权沿用；本轮服务端新搜索/索引发布待具体候选后独立授权。
- [设计](../../superpowers/specs/2026-09-27-friend-video-followup-design.md)、[计划](../../superpowers/plans/2026-09-27-friend-video-followup.md)。
- 当前：三渠道POST/末尾两位容差、blur校验、相册重复订阅与原片预览、视频顶部提示删除均已实现并独立复审。Debug2184已覆盖安装，运行时诊断enabled=true；完整仓库verify退出0，API e880ec8e与0090已上线，双侧TLS检查通过。
- worktree：C:/Users/Administrator/.codex/worktrees/friend-video-followup/StarChat，branch codex/friend-video-followup，移动源码commit05a2d950047f96d128fc1115cb7db5bec39db017；1753文件冻结manifest f0663c0fa843ca778ef183bf308bbc0714ca8597268d2b02185ca391129fe597。继承既有account/6f与regional增量，纳入c936快失败classifier。
- 实际设备：emulator-5556，0.4.15/2184，x86_64，最后更新2026-09-27 12:43:02；首次安装2026-09-26 04:06:20保留。APK e49ad21446b3bff8bdaef1a3dec5bb0329e01e5cc095996c857ba4d29d141ba9，稳定签名75b31c66…。
- 所有权：后端搜索inspect_profile_identity；视频和独立审查inspect_live_account_api；contacts/trace增量inspect_account_loading；root改号/HTML/contracts/整合。原发布agent网络压缩中断后由finish_search_release接手，保留已有候选/恢复证据，不重做构建和恢复。
- 工程交付完成：最终发布独立复核PASS，主目录源码、文档与索引同步；下一步仅收真实已绑定账号改号及原生视频人工反馈。

## 验收台账

| ID | 预期 | 当前证据 | 缺口 |
| --- | --- | --- | --- |
| D1 | 最新全链路诊断不回退 | 35专项PASS；2184实际runtime enabled=true，36recent/1active；receiver6033保留 | 真实视频设备播放/跨网摘要用户观察 |
| S1 | email/phone exact，用户名末尾最多两位 | 后端合并52PASS/PG16索引与16并发；Contacts156PASS/transport22PASS；QR精确匹配；e880/0090已上线、双侧TLS/401 | 真实用户账号检索人工验收 |
| U1 | 说明美化/失焦校验 | username9PASS、HTML21PASS；旧响应/跨账号/写冲突可用性复核通过 | 真实已绑定账号改号人工验收 |
| V1 | 相册原片可预览 | 重复单订阅流实际pipeline red/green；原片优先；退出trace3RED→15PASS | Windows无native CUA；已安装包原生样片播放未操作验证 |
| V2 | 去掉朋友圈/房间视频加载toast | explicit/bare顶部胶囊清除；held inline加载/失败/重试2PASS；HTML9状态 | 用户对应真实视频人工反馈 |
| I1 | iOS0.4.7启动提示原因 | 2173源9eb41e8f分类缺口；用户确认覆盖更新且解锁/重试/重开无恢复，弱化暂时锁机解释 | 准确build/iOS/设备安全错误类别缺失，不能定单一根因 |

## 证据与计时

docs/verification/artifacts/2026-09-27/friend-video-followup/：original-input-snapshot.json、diagnostics-latest-inclusion.json。准备精确起止待后续实际clock/工具回执；不从mtime估完整工时。所有私有备份/用户数据不下载。

## 交接

保持财务、认证、E2EE恢复边界；iOS问题不以清数据/换Matrix身份处理。手机号沿用phone_findable、自己/拉黑与共同限流。相册源文件不删除，发送20MiB/H264AAC不变。独立network receiver发布进行中，仅核对，不竞争生产写入。

## 2026-09-27 实施与审查进展

- 用户确认 a1111144 也匹配 a1111123；候选n∈[m,m+2]，比较前n−2位。邮箱手机号完整等值。因默认URL访问日志风险，新版改认证POST `/users/search` JSON q；旧GET手机不开放。详见 [ADR](../../adr/2026-09-27-bounded-friend-discovery.md)。
- Contacts156PASS、username9PASS、transport/version/HTTP metrics22PASS、诊断35PASS；后端合并52PASS，HTML320PASS/UI33组件467屏。追加HTML视频映射待最终屏数同步。红、环境错误与真实失败均保留，不能把首轮组合41PASS/1FAIL写成exit0。
- 后端独立domain→security PASS（reviews final）；0090 PG16真实线上/离线、invalid/partial/ordinary index拒绝及6查询/16并发通过。API候选从现场bb108b47 receiver增量准备，生产schema0089/worker15659不动。
- 视频相册和transcode重复订阅单订阅进度流在encoder调用前抛错，已有真实pipeline red/green；预览借用原片、发送保持20MiB/H264AAC。Loading保留inline，两个顶部胶囊及bare隐含胶囊均关闭。退出held loader/decode/fallback trace的3red→15green关闭active容量泄漏，新增增量独立复核中。
- 最新diagnostics classifier三文件保持c936，fullchain6f及regional客户端源保留。现场receiver source SHA6033c300…，生产APIbb108b47已经由独立授权任务发布；最新receiver/collector/test已逐SHA同步。本轮不覆盖它。
- 固定依赖恢复实际2183使用的52207159…锁；原D锁7d带3个无本轮需要的升级，备份保留。所有后续Flutter用--no-pub。R短盘、本任务E命名verification build junction准备，原322生成文件/bytes/SHA验证后搬迁；不删其它工作树输出。
- iOS覆盖更新/解锁重试无恢复，[调查说明](../../verification/2026-09-27-ios047-startup-investigation.md)确认unknown提示分类缺口，准确设备cause仍缺；未改认证/E2EE或清数据。
- 上述为打包前快照；之后完整verify已退出0，Flutter旧视频顶部提示断言仅测试文件修正并2PASS，原full退出1保留。HTML最终332PASS及21增量PASS，UI33/476；移动commit05a2d950/1753文件已冻结，18重建步骤0，2184保留数据安装和runtime enabled=true闭环。

## 2026-09-27 生产授权与交付收口

- 用户在call_10ikDzCzm5ns77ETyTIkHfFq批准API e880ec8e候选和0090；此前9083/0089授权没有被扩用。14:08:27.971+08生产健康切换完成，服务器verify与工作站TLS退出0。
- 候选独立复审 f1e95590… PASS，11允许目标/1057未变、receiver6033、实际默认入口导入与TCP、138表一致恢复和旧bb+持久0090只读兼容回退已闭合。
- 主目录49个本任务变更按源/目标SHA预检后回填，保留并行SG、receiver/collector及其索引记录。OpenAPI只增加搜索请求体/POST/旧GET说明，最新receiver部分保留；回填前备份在本任务verification目录。
- 原生播放样片已进入模拟器DCIM/StarChatVerification2184；H264/AAC、静音、实测display-matrix旋转90°各逐SHA核对。只证明样片准备与安装，不宣称已操作相册/朋友圈/房间原生播放。
- fresh一致备份13b2b4a5…/27945087字节/138表server-only；0090 valid非unique非partial，actual/opt源/receiver6033保持；API0重启/error/warning0，worker/PG及25其它容器不变。Mounts顺序误报原exit1保留，全字段排序等价守卫fresh0后才执行发布。
- 最终发布独立spec/domain→quality/security复核PASS、无开放发现；双侧TLS、私有backup0600、rollback目录0700/迁移0444与关闭SOCKS均确认。见本任务artifacts/reviews/postrelease-final-review及server-release/deployment-report。
- 主目录1753移动文件复核：1086字节相同、664仅LF/CRLF、3仅声明/注释/widget参数间空行；无行为差异，未覆盖其它任务或批量改行尾。原两次字节/行尾检查失败记录保留并由明确差异复核闭环。
- [完整验证记录](../../verification/2026-09-27-friend-video-followup.md)保存计时、原失败、复用依据、稳定签名及设备/服务身份。下一步仅收真实账号和原生视频人工设备验收反馈。
