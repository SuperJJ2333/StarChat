# Android2214图片/视频发送红叹号回归

## 恢复入口

- 用户报告：Android0.4.45+2214会话内图片、视频发送均红叹号，用户称所有机型；本轮尚未将该范围作为独立实测结论。用户明确要求修复并把debug安装到模拟器实测。沿用此前修改/重启/部署授权，无需重复请求。
- 关联：[批准的IM修复计划R8](../../superpowers/plans/2026-10-11-im-reliability-remediation.md)、[前轮实际发布](../../verification/2026-10-11-im-reliability-release-result.md)。本任务单列P0媒体发送回归，不改旧通过证据。
- Root工作树：C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat，codex/im-reliability，起始0ef24bd1（运行时e9d297），tracked干净。primary仍5c83及原评审未跟踪文档，保留不覆盖。
- owner：root拥有媒体最小修复/失败测试/设备操作/任务与计划；media_regression_trace只读追客户端；backend_review只读聚合服务端。当前未授权其他agent同时改产品文件。
- 最后更新时间：2026-10-12T19:17:40.677831+08:00；状态：2215 debug真实图片/视频UI及服务端同步通过，正式ARM64包28门禁通过；下一步：冻结离线package最终双审→逐阶段发布→平台隔离/审计/公网后验。

## 验收台账

| ID | 场景/预期 | 当前状态 |
| --- | --- | --- |
| M1 | 图片从实际房间入口准备→加密上传→事件ACK成功，无红叹号 | 2215真实相册发送/ACK PASS；见对应receipt |
| M2 | 视频从实际房间入口准备→加密上传→事件ACK成功，无红叹号 | 2215真实相册发送/ACK PASS；见对应receipt |
| M3 | 最小根因回归RED→GREEN，重试/取消/账号/大小及相邻媒体路径保持 | RED→GREEN14/邻接7/独审14；最终Flutter5965+9skip、Python401+1skip、analyze0 |
| M4 | 固定签名/常规重建debug安装至模拟器，保留已有数据，实际图片/视频验证并记录SHA/机型/版本 | 2215固定75b31 debug保数据覆盖PASS，UID10090保持；实际UI/ACK/播放与进程重开已验 |
| M5 | 独立规格→质量、安全与最终适用共享门禁；需要正式修复发行时递增版本并独立记录 | 源码双审通过；2215发布准备32PASS及独审32PASS；最终5965/401/analyze门禁、成品双审及正式发布/后验通过 |

## 设备与边界

2026-10-12已观察两台Android9/API28 x86_64兼容模拟器在线：5556现有com.liuhetong.mobile.debug为0.4.43+2212且前台为已有测试群，5558无畅聊包。禁止清数据/卸载/向现有多人群发验证内容；优先当前账号仅自己可见的测试房间，不读取/导出会话token或密钥。root可检查签名连续性后保数据覆盖5556；如新debug需在5558测试，独立取得合法测试登录，不伪造生产身份。设备实验不能代表全部手机或ARM64/16KB验收。

## 计时与证据

开始：2026-10-12T19:17:40.677831+08:00；工具实际计时分别记录。证据仅放docs/verification/artifacts/2026-10-12/android2214-media-regression/；原始截图、APK、运行数据不入Git，错误摘要脱敏。无.env的全仓verify预检限制继续保留，但本次有新产品修改必须完成影响门禁，不能复用旧5958来宣称新源码通过。

## 2026-10-12复现与最小修复

- 源码根因：`_bindConnectionStatus`间接进入`_bindMediaOutbox`时generation为0，secure binding的await后`_startup.open()`已推进为1，因此有效账号也被过期检查拒绝，图片/视频共同`owner-unavailable`。最小改动是先open/ready再bind，保留代际、账号、撤销与E2EE保护。原提交ccd45e8e，root集成4024d2a8；当前产品冻结ec9a38a8（0.4.46+2215）。
- 未修复main debug2214 SHAeec916a1…015f8、125933914B、x86_64，常规重建/固定75b31签名/语义比较PASS；12:22:38Z保数据覆盖2212→2214，UID10090不变。首次签名DPAPI换行解析失败留证，修正仅trim序列化密文，签名身份未改变。
- 实际唯一成员加密测试房间从真实SDK创建，经公共导航回调进入普通RoomPage，相册UI发送自制JPEG红叹号、MP4提示暂无法发送，queue.active=false。原始截图仅本机、脱敏receipt入证据；未向任何已有多人房间发消息。
- [复现证据](../../verification/artifacts/2026-10-12/android2214-media-regression/baseline-runtime-receipt.json)、[源码RED/GREEN](../../verification/artifacts/2026-10-12/media-send-startup/README.md)、[独审](../../verification/artifacts/2026-10-12/media-startup-independent-review/README.md)、[服务器只读排查](../../verification/artifacts/2026-10-12/android-2214-media-server-triage/REPORT.md)。服务端窗口六次media upload200不能归属本次2214，不据此声称全部成功。
- 修复debug构建run：fixed-main-debug-2215，独立最终门禁owner media_regression_trace；root拥有设备、源码版本、文档与正式交付。iOS正式2213及Android厂商通道审核边界保持。

## 修复候选实际验收

- Debug main x64 0.4.46+2215：SHAe3bd89359c3822e54dc6c6daa28d12c0117ff6f25f7c7a968eb03416d507ac2a，125901146B。12:38:03–12:45:29Z构建/常规重建完成；12:52:29Z保数据覆盖2214→2215，UID10090保持。图片相册发送m.image/synced/serverIDtrue且原图13K可开；MP4视频实际播放帧/进度0→2秒（总3秒），跨进程重开PID10821→11824仍m.video/synced/serverIDtrue，queue.active=true。仅一人加密测试房间，未向已有群发送。
- [真实复现/修复入口](../../verification/artifacts/2026-10-12/android2214-media-regression/README.md)、[最终共享门禁](../../verification/artifacts/2026-10-12/media-2215-final-gates/README.md)。5965PASS/9SKIP/0FAIL、analyze0、Python401PASS/1SKIP；whole verify真实exit1缺本地.env，不冒称全仓通过。
- 正式ARM64 0.4.46+2215：source9990ca6e、2102移动输入manifestfb3e8fd4…a4e42d，固定locka43833c8；13:25:17Z成品73262170B/SHA4b43bd1ca655918b9754183c1713ed5eb6e864379a2e2ccc6bd861195578b6a6，28步骤exit0、固定75b31/v2/v3、nondebug/min24/target36、25414class/168863methods/274lib+assets语义一致，锁屏400source/57class严格闭包复用。未称16KiB ELF已解决。
- 离线package：android2215-release/publication-final-2215-20261012，freezeb93b674b717219871374dbe94fb4c6fcd0f6810dccf598f691d544532b4511c8；operation_id mediafix-20261012-2215，待最终双审通过后执行（用户原部署授权有效）。此刻没有公开发布，正式Android2214/iOS2213。
- 共享测试树到正式树2096raw相同、6项严格CRLF/LF字节等价；生成插件仅日期/6个本地路径，两个插件105/29文件库存与raw相同，由独审精确证明，未写全部raw相等。
- 追加设备截屏曾遇到前台已被外部操作切走，丢弃无关截图并停止设备交互；此前已采集的合成媒体/ACK是有效证据。debug保持已安装，不宣称仍前台或代表全部机型。

更新记录UTC：2026-10-12T13:43:53.111992+00:00；正式发布后验待执行。

## 最终发布闭环（2026-10-13记录，发布发生于10月12日）

M1–M5已完成既定范围。实际执行r2 freeze d08e5c8a…a558b；旧b93b包未执行。10月12日22:25+08 PUBLISH_PASS、22:28 ROUTE_AND_AUDIT_READBACK_PASS、22:31工作站8请求/11断言PASS。Android0.4.46+2215正式分发及更新配置启用，iOS2213/min3保持。两文件源码回填按SHA CAS完成；五个保护文件保持。此前“待发布”段落仅阶段历史。真机全ROM、独立接收端、16KiB既有风险仍为缺口，不阻断已完成的模拟器修复证据。详见修复报告。
