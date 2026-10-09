# 2203 图标、弱网历史跳转与服务器卡顿

## 恢复入口

- 用户2026-10-07四项反馈：模拟器0.4.34+2203 emoji/icon缺失、正式Android0.4.33弱网历史插入旧日、明显卡顿、快速上滑跳十几天前。用户“请你继续”授权沿已有修复工作继续；确认未部署xmrig，并单独选择应用只禁止root密码登录的SSH加固。
- 状态：**移动源码/回归/标准重建/独立实际包审查通过，0.4.35+2204已保留数据安装模拟器，同源ARM64 release本地候选已双审接受；服务器止损与SSH加固独立验证完成；待用户场景复测**。
- 源commit `3a620495ae048d3e4141f099e1926ecedc8669cd`，分支 `codex/history-icons-performance-2204`；worktree `C:/Users/Administrator/.codex/worktrees/history-icons-performance-2204/StarChat`。未合并或推送main；main仍be207f0fece77f0a4585790d7c0932368ac63146，1373项原WIP不并入此任务。
- [计划](../../superpowers/plans/2026-10-07-history-icons-performance.md)、[完整验证报告](../../verification/2026-10-07-history-icons-performance.md)、[证据目录](../../verification/artifacts/2026-10-07/history-icons-performance/)。
- 文件所有权：font_icons负责独立完整资源gate/Python测试；history_scroll/history_finish负责SDK Room/Client/Timeline、窄pinWindow与历史测试；client_lag_trace负责watchdog/RoomPage计时与测试；root负责版本、测试fixture环境修正、构建、记录、索引；不并发编辑同文件。最终源码有序SPEC/QUALITY与增量审查均接受。
- 最后更新：2026-10-07T19:05:34.002005+08:00。
- 下一条具体操作：模拟器用原账号检查emoji/icon及弱网连续快速上滑；手机使用已验收的ARM64 release候选覆盖安装，x86_64 debug仅供模拟器。正式更新发布未执行，iOS未构建。
- 安全边界：不输出/保存消息正文、用户密钥或原始敏感取证；保留E2EE/权限/撤回/业务钱包边界，无金融写入、无测试消息/通话。

## 验收台账

| ID | 场景 | 实现/测试证据 | 当前交付 | 缺口 |
| --- | --- | --- | --- | --- |
| F1 | emoji/icon加载 | C:/S:缓存路径清理导致实际旧包资源缺失已证；独立新缓存/单一路径；源/最终完整资源gate及22+5测试通过，2套字体/56emoji/225SVG存在且字节正确 | 2204已安装，启动资源错误0 | 逐页视觉复测待用户 |
| H1 | 弱网历史连续 | limited-sync期间旧HTTP/缓存回写混合片段已复现；代次guard、独立历史副本、缓存ID游标与真实context；含撤回在途边界，54专项+26列表通过 | 修复在2204模拟器候选 | 待原手机覆盖ARM64候选后弱网反馈 |
| H2 | 快速上滑保持位置 | 变量高度列表/context在途/limited sync/窗口裁剪、实际反向拖动及真实SDK传输回归通过；可见锚点像素保持 | 同上 | 真实长历史连续快滑待反馈 |
| P1 | 卡顿根因核查 | 未授权挖矿4核/2.29GiB已停用；CPU回落3.78%/可用内存4GiB；服务器历史p9568ms。同步阶段假进度污染已修正，82专项通过 | 服务器止损/SSH已生效；客户端候选已安装 | 历史监控不完整，不能证明所有卡顿已消除；新包真机帧/阶段复测 |
| S1 | root密码登录加固 | 用户明确批准；final21/22新公钥连接/仅root策略差异/七容器保持均exit0 | 16:32:02.952+08已独立验证 | 完整入侵路径/其他驻留排除尚未证明 |

## 版本与验证身份

- 用户症状版本：模拟器0.4.34+2203/正式Android0.4.33；“最近一小时”按约15:04回复对齐14:04–15:04+08，手机型号/具体网络未知。只读18:24正式Android0.4.33+2202、iOS0.4.25+2194。
- 候选：com.liuhetong.mobile.debug、0.4.35+2204、x86_64 debug。APK135803107bytes，SHA `221aca2d4ea486673b650b0a7ca4d580f9c2655c7337bd74bd8e93de6a353b5c`；稳定75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff单签v2/v3。
- [APK](../../verification/artifacts/2026-10-07/history-icons-performance/delivery/ChatFlow-0.4.35-2204-x86_64-debug-rebuilt.apk)、[构建身份](../../verification/artifacts/2026-10-07/history-icons-performance/android-debug/run-20261007-182759/artifact.json)、[独立实际包审查](../../verification/artifacts/2026-10-07/history-icons-performance/artifact-review/acceptance-metadata.json)。
- 冻结1881输入manifest SHA76d10524056a5efe9da34f679bd3b69de046859d9f67a372a0f13883b9f8d840；lock ac0966cb75f61763073bfc48ef5e8b93b85cf6cf46ebaa921d8b3739c62694ac；Windows/pwsh7 UTF8、Flutter3.44.9/Dart3.12.2，所有Flutter命令只用U:。无.codegraph、不创建索引。
- analyze exit0无问题；完整Flutter5501PASS/9skip/0FAIL exit0；移动Python354PASS/1skip exit0。Android native59PASS按输入不变复用；新iOS编译/IPA NOT_EXECUTED。ARM64 release候选已构建并独立双审接受，未真机安装/发布。整库verify.ps1预检缺.env/local.env，NOT_EXECUTED，未引入生产秘密。
- 保留数据安装18:36:10–18:36:46 exit0，UID10090/首次安装时间保持，实际base.apk SHA一致；18:38:55同PID8170持续129.141秒，聚合fatal/资源/字体异常0，仅启动smoke。
- 首轮Flutter28FAIL（27旧测试父目录缺失+1真实SDKfork后Fake fixture失效）、Python1FAIL（既有摄像头静态fixture）已留失败与基线重现，修复目录/fixture后最终重跑通过；未以文件名含green而退出非0的日志作PASS。详情与命令/时间/审查身份见完整报告。

## 阶段计时

| 阶段 | 开始 | 结束 | 性质/并行 | 结果来源/下一步 |
| --- | --- | --- | --- | --- |
| 本轮精确基线与定位 | 14:55:56+08 | 各专项持续至最终审查；更早起点未知 | 资源/历史/服务器并行 | baseline及真实RED；不按mtime编造各专项工时 |
| 挖矿止损 | 精确开始未单独记录 | 15:03:53+08 | 服务器限定变更 | stop/disable0、业务保持、受限取证 |
| SSH最后应用与新连接 | 16:28:42+08 | 16:32:02.952+08 | 用户单独批准 | 21/22最终成功；较早超时撤回不混用 |
| 最终移动Python | 17:42:58.199+08 | 17:43:34.674+08 | 工具 | 354PASS/1skip/0 |
| analyze/Flutter全量 | 18:17:22.187+08 | 18:22:14.895+08 | 工具顺序 | 0问题、5501PASS/9skip |
| 标准构建重建验包 | 18:28:01.763+08 | 18:32:46.509+08 | 工具约285秒 | 所有steps exit0 |
| 独立实际包双审 | 18:35:34.573+08 | 18:35:34.965+08 | SPEC后QUALITY | 两者ACCEPT，独立实际检查已完成 |
| install-r | 18:36:10.881+08 | 18:36:46.210+08 | 工具 | 版本/UID/首装/实际SHA一致 |
| 启动观察 | 安装启动后 | 18:38:55.345+08 | 外部运行观察 | 同PID129.141秒/匹配异常0 |
| ARM64首轮/旧helper重试 | 18:49:12.485+08 | 18:51:33.513+08 | 工具失败返工 | dev注册/旧S路径已证，旧生成文件逆补恢复 |
| ARM64限定生成文件修正后构建 | 18:56:25.638+08 | 18:59:01.703+08 | 工具156秒 | 所有step0、同源freeze/稳定签名/完整资源 |
| ARM64实际双审 | 19:03:49.009+08 | 19:03:49.308+08 | SPEC后QUALITY | 独立11工具/native-lock均0 |
| 文档归档与索引 | 启动后 | 见闭环回执 | 主动/并行 | hash/链接/WIP保全检查 |

首精确基线至启动检查墙钟约3小时43分；并行区间不累加。未知更早工作时段明确保留未知。

## 交接与回退

- 挖矿原件服务器root-only `/opt/starchat/incident-evidence/20261007-xmrig` 保留；没有业务/Matrix容器重启。登录与挖矿时序有关联，不冒称已完整查明入口；17:55最终只读资源压力已下降。
- SSH drop-in `/etc/ssh/sshd_config.d/00-root-publickey.conf` SHA6baa3b9db6ba061119f950eef67c64e205182d3310654a861b844c247ba3cb21；main config及端口/公钥/其他用户策略保持，最终新连接成功。必要回退只能移除本任务这份drop-in、校验并reload，不修改其他规则；不得无漂移检查盲目覆盖。
- 尚无新正式移动发布或更新弹窗/下载页面切换；ARM64同源本地候选已验收；新iOS签名/编译亦未执行。真实字体显示与弱网滚动/卡顿反馈是后续场景验收，不能用启动smoke代替。
- 本任务分支与managed worktree保留，U:指向本候选，S:旧缓存不动。未申请合并/推送；下一次改源需新冻结/影响比较，不能把源码commit变化后的产物冒认为本包。
- ARM64首轮失败与修正证据保留；新run-20261007-185625已exit0结束，session94967已关闭。无运行中CI/构建或本任务隧道。日志归档为选定文本及hash清单；APK独立交付副本保留在主区delivery；不得把服务器原始敏感日志复制进仓库。

## ARM64技术交付完成

0.4.35+2204、com.liuhetong.mobile/standard ARM64 AOT release，82848798bytes，final SHA a2d100be2e0273107d231dfd82fee316c89d3c1cb37ff976ba36d8f2fcf835e5；同源3a620495/1881manifest/原lock，固定75b31 v2/v3、P16，全字体不裁剪/不混淆。新run所有step0、19:03:49实际SPEC→QUALITY ACCEPT，319Flutter成员/310声明资源/338原生资产保全；APK在主区delivery/ChatFlow-0.4.35-2204-arm64-release-rebuilt.apk。没有真机安装/正式发布；源branch未合并/推送，后续纯文档commit不改变APK来源3a620495。

ARM首轮dev类错误及继承helper硬编码S的失败已留证：旧Signored生成Java9046字节精确逆补恢复；本地SDK --no-pub跳过平台注册刷新，使用本任务候选路径限制helper仅删274byte已知dev条目，其余byte/所有生产插件保持，5项正负例及独立边界审查通过。移动源/锁/SDK未变；不用首轮失败作PASS、不重跑未改变完整共享门禁。

18:51:04最后只读CPU6.97%/MemAvailable4006.9MiB，xmrig inactive/disabled/0PID，同名进程0；仍不称完整入侵清除。首基线至ARM实际接受约4小时8分，归档文档闭环另计。下一步原手机覆盖新ARM候选，复测弱网/快滑/图标/卡顿并记录手机型号、网络及北京时间；源码/产物/权限边界见完整报告。
