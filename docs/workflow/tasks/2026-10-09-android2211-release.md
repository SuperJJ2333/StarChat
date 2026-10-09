# Android 2211 正式分发与更新弹窗

当前：分发及服务器更新弹窗配置已完成；真机反馈待确认。

授权：用户2026-10-09明确要求“推送Android新版本的更新推送和更新弹窗”。范围：同源0.4.42+2211 ARM64正式构建、官网/CloudFront分发、普通Android更新弹窗；不提高最低build、不改变iOS、不发送任意账号聊天或群广播。
开始可靠计时：2026-10-09T10:03:14.777297+08:00（实际调查稍早，准确起点未知）。
计划：[本轮发布](../../superpowers/plans/2026-10-09-android2211-release.md)。
源：managed W树b09bf2f2+既有WIP，debug2211已验证输入1935；相关共享全量5730/9、analyze0、native5、边界377/23和双审复用需逐项指纹确认。正式包与debug包分开构建，75b31固定签名；source未合并。
所有权：本任务record/plan/artifacts、Android官网元数据/版本设置、56固定资源不可变分发路径。服务器运行镜像/钱包/业务API不部署。

| ID | 验收 | 状态 |
|---|---|---|
| R1 | ARM64 release2211固定签名重建、精确输入、资产/清单/DEX/SQLCipher校验 | PASS（详见发布闭合与报告） |
| R2 | 官网与CloudFront不可变包可访问，旧包保留、alias切换可恢复 | PASS（详见发布闭合与报告） |
| R3 | Android普通更新弹窗、版本/说明/唯一审计，iOS/minimum保持 | PASS（详见发布闭合与报告） |
| R4 | 独立动态资源56条逐项SHA/大小/URL，CDN可下载 | PASS（详见发布闭合与报告） |
| R5 | 新/旧客户端平台路由、401、工作站与服务器HTTPS、运行服务保持 | PASS（详见发布闭合与报告） |

真机保留数据覆盖、弹窗实际出现及profile仍待用户反馈，不以静态/模拟器通过冒充。
初始下一步（历史）：实际HK/SG只读基线→正式构建→准备双审→上传资源/包→CF→官网/SettingService→公网与审计闭合。

## 发布闭合 2026-10-09T10:23:02.724266+08:00

R1-R5分发/服务器验收PASS。0.4.42+2211ARM64正式，73139489bytes/SHA4eb0f8bb7fc3dd9f1f3f85cb4a73489b3cc8ae5841f0114a6d9cb7766d80751e；28重建gate、18发布测试、Nodeprimary54/managed51、shared5730/9/analyze/native5等精确输入复用、policy3PASS、双审通过。10:19:43PUBLISH_PASS，exact3audit与实际两端/legacy投影；CloudFront14Deployed/官网与工作站HTTPS/56资源源站+CDN逐项SHA通过。iOS2205/min3/schema0095/35服务及旧包保持。
详细[报告](../../verification/2026-10-09-android2211-release.md)，0700备份/回退路径见报告。个人使用资源授权沿用；未发布差分API，无真实手机弹窗/升级/profile声明。所有命令结束，自建SOCKS关闭，无合并/提交。
下一步：用户在手机不卸载覆盖安装，反馈弹窗和表情/房间/键盘体验；有实际问题沿准确版本和时间诊断。
