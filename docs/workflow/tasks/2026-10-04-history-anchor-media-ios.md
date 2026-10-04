# 历史消息定位、旧媒体及iOS连续性修复

## 恢复入口

- 用户反馈：五天前聊天搜索点击显示“未找到该消息，请稍后重试”；图片/视频昨天及更早仅占位。用户确认模拟器2198和真机2196，要求预防iOS L04/L07而非报告当前iOS故障。
- 授权：本会话直接修复请求，沿原任务自主实施与ADR决策；[计划](../../superpowers/plans/2026-10-04-history-anchor-media-ios.md)、[原托管ADR](../../adr/2026-10-04-server-custodied-matrix-recovery.md)。
- 基线main3b9d7c24；新branch codex/history-anchor-media-ios-20261004，复用隔离工作树。主目录WIP不修改。当前状态：源码有序双审接受；最终Flutter5419PASS/9skip、analyze0；2199debug已保留数据安装/smoke通过；同源iOS三job全部success；已合入本地main，源码/平台门禁完成；远端交付与WIP保留结果见integration-result.json。
- root拥有本记录/计划/索引/最终证据；独立ios_l04_l07_investigation仅只读调查，无源码或Flutter动作。Task1/Task2顺序独占源码和工具。
- 记录时间2026-10-04 17:36+08，调查准确起始时间未知，不以文件mtime编造耗时。下一步Task1真实失败测试→最小修复；Task2真实SDK身份回归→定向修复；整批及平台交付。

## 验收台账

| ID | 预期 | 调查/实现 | 测试/发布/缺口 |
| --- | --- | --- | --- |
| H1 | 五天前可访问消息能定位气泡 | 统一本机/网络单事件会话校验及解密，再检查可见性；真实五天前加密保留库RED→GREEN | 2199debug已安装；真实账号/真机待反馈 |
| H2 | 旧图片视频缩略图和正文可按需加载 | 按ID解析窗口外事件并使用已验证来源及有界账号/房间缓存；旧加密图片/视频RED→GREEN | 2199debug已安装；真实账号/真机待反馈 |
| I1 | 密钥加载不会使iOS登录/账号存储永久L04/L07 | 真实SDK复现首次owner失效、采纳超时身份分裂、旧Olm标签与异常context；已最小修复 | 九个实际SQLCipher/Olm场景通过；iOS18/26原生seed及原库/keychain保留verify全部通过，未报告用户当前iOS故障 |

## 边界

2198 debug已装模拟器；正式Android2196/iOS2194沿上一轮发布事实，本轮需重读后冻结新debug号。原服务已启用，但不把其技术验收当真实用户历史恢复。保持本机历史/Olm/SQLCipher/keychain、房间/账号绑定、金融域及敏感日志规则；不清除数据、不重置密钥，不泄露用户事件/媒体内容。

### Task1实际RED/GREEN与新增共享边界（2026-10-04 17:53+08）

独占actor以真实keyed SQLCipher文件重开、native Olm和五天前密文验证：文本锚点false，图片/视频loadThumbnail unavailable，3项RED exit1；修复后16实际加密场景PASS，含room/sender/session错误、坏媒体key、撤回隐藏、missing-key重试、owner撤销/异账号/迟到读取及实际index写drain。尚待commit/hash/最终analyze。

154定向测试中2个原content_addressed_media测试被新正确owner检查拒绝；根因候选：factory先initialize真实SDK Client再创建wrapper，constructor捕获null数据库generation，首次continuity读回赋generation后旧owner失效但未重绑。Task1fixture在已合法owner情况下独立验证resolver，不能宣称正常启动已通过。Task2需要真实正常factory/continuity流程，无fixture手动callback捷径，保持检查并修复。

Ruling：共享启动缺陷使原Task1先全绿→Task2顺序形成依赖循环。允许Task1冻结commit并静态双审/释放共享文件给Task2；Task1不标complete，Task2关闭两个实际失败及factory启动RED后，再合并验证和最终双审。保留所有失败记录，不弱化断言。

### 合并源码门禁（2026-10-04 18:40+08）

Task1 9481b1b3与Task2 8b11aa4a均按规格/领域→质量/安全审查接受。Task2实际SDK+保留keyed SQLCipher/native Olm复现首次owner失效、采纳超时内存/持久身份分裂、旧Olm设备标签及异常重试context；最小修复后245PASS/0skip、analyze0，移除Task1手动callback并关闭原两个contentmedia失败。新iOS原流程保留keychain/DB同模拟器seed→重启verify已扩展，尚未原生执行。

Root全Flutter18:36–18:40，exit1：5417PASS/9skip/2FAIL，均group_announcement_sdk_recovery测试替身漏session_id接口，原生产会话绑定校验不放宽；actor正仅补接口并保留negative断言。mobile Python307PASS/23skip（61.54s），exit0。整库verify.ps1因.env/local.env缺失未启动，不能宣称全仓绿。

18:37只读线上Android0.4.27+2196/iOS0.4.25+2194；2199调试号待最终配对冻结。未正式发布/改服务。自动审批拒绝两个失败synthetic fixture目录清理，仅blocked by policy；保留ignored、排除交付，无绕过删除。

### 最终候选与Android包（2026-10-04 18:52+08）

冻结源码df61718772b4c82f3063f1034a93e2c028160735（0.4.30+2199），1867mobile输入manifest8348714a26860fba2dabf32483822b1bdb352dc0a173dd927456b4776867945b，锁ac0966cb保持。最终Flutter5419PASS/9skip/exit0（3m53s），analyze0/exit0（27.7s），输入复核不变；旧exit1保留。公告fixture字节hash229743fb系243CRLF+9LF，normalize精确等Gitblobcf263cc9，不是源码差异。最终增量双审candidate-review.md接受，无P0–P2。

同源iOS原生run37196458099已于18:46启动，完整productioncompile及iOS18/26同BundleID/simulator seed→terminate→verify，当前pending。mac host没有额外Olm/SQLCipher动态库，不把Windowsffi测试放入不支持环境；新增共享fixture在必做nativeintegration中运行，原host增加公告7项。

Android构建18:49:15–18:51:33（2m18s），standardx64debug按源码→Apktool2.12.1→zipalign36/P16→固定签名完成，所有steps0。final.apk135721187bytes，SHAe3923bc093c6a1850129086571785935e7465316799408f6e6f4e5780a815122，证书75b31c保持。输出run-20261004-184915，独立artifactreview双审通过（d3a6a0fc…）；18:59 install-r保留UID/firstInstall，19:02完成157秒process稳定/crash0smoke。

自动审批再次拒绝仅移除旧buildjunction并切到新cache的命令，未执行；选择保留原junction/reuse既有命名disposablebuildcache，driver精确target校验并记录metadata，旧immutable2198finalAPK不受影响。两失败syntheticfixture目录保留ignored且不分发；无绕过删除。

### iOS终态与集成入口（2026-10-04 19:15+08）

run37196458099 head精确df617187，全部三个job success，iOS18/26 host、native seed、同app重启保留verify各success。完整原生编译含production插件组合；模拟器scanner已有架构限制保留。真实iPhone企业签名覆盖升级/真实用户历史与Android真机仍待反馈；本轮不构建IPA、不正式发布。全域脚本仍因缺.env未执行。

Android2199最终包已独立双审、保留UID/首次安装时间覆盖安装，157秒smoke/crash0。公共工件按显式文件清单复制主目录，无数据库/key目录；原2198成品保持。main/originmain均3b9d7c24，无并发远端变化。下一步仅文档收尾提交→独立最终证据审查→保留primaryWIP的fastforwardmain/push/readback，本轮源码相关输入不再改动，不重复已覆盖门禁。

### main集成执行（准确开始时间未采集；收尾文档Git提交时间2026-10-04 19:24:05+08）

最终debug/native双审final-delivery-review.md接受，hash71d34a23fb660d605cc843c21052070db304d7192367c11fdb955a80484a2816。初次本地main fastforward到7016ea91；仅current-state的自有stash61dde020已apply --index成功无冲突，主目录1372既有trackedWIP内容hash全部保持、原index为空仍保持。原状态文档修改恢复，未提交他人改动。公共工件最终53文件加inventory按显式清单核对，无数据库/key目录。

本轮技术scope完成；真实账号/实体设备/正式发布缺口如上。远端main推送、精确readback和仅本轮branch清理由integration-result.json绑定；docs-only收尾与df617187的mobile/workflow差异必须为空，复用已通过全量与原生门禁，不重复CI。下一步为真机/真实用户历史验收，正式Android/IPA发布需单独指定。
