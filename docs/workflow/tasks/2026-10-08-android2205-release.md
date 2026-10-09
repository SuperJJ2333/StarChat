# Android2205发布与更新弹窗

## 恢复入口

- 授权：用户“好的，请你开始推进，然后推送Android新版本更新弹窗”。普通可跳过弹窗，保留最低build3。
- 计划：[发布计划](../../superpowers/plans/2026-10-08-android2205-release.md)。状态：正式发布及更新弹窗完成，待真机反馈。
- 所有权：本任务记录/计划/证据；Android官网下载元数据和对应设置；managed c628源码只读构建，不覆盖其他WIP。
- 工作树：C:/Users/Administrator/.codex/worktrees/history-icons-performance-2204/StarChat，HEAD c628fe2e6706000cd721d6118c3e8ef8d372d7e2。
- 开始：2026-10-08T20:06:34.4507548+08:00。下一步：用户不卸载覆盖升级2205，复测大历史/快滑/弱网/首次语音；K80退出原因另行定位。

## 验收台账

| ID | 预期 | 状态/证据 | 缺口 |
| --- | --- | --- | --- |
| A1 | 正式APK包含大历史有界加载、快滑、弱网排序及语音修复 | 共享源码3c37b529，c628版本2205；待实际包 | 真机暂不可USB |
| A2 | 固定签名重建与实际内容门禁 | 待构建 | 不将profile中间包分发 |
| A3 | 官网与CloudFront分发，Android普通更新弹窗 | 待生产 | iOS保持2205/min3 |
| A4 | 后台重入闪退 | 服务器聚合检查另见crash任务；根因未证实 | 需ApplicationExitInfo/logcat，不能称本包已修复 |

## 验证复用

共享5632PASS/9既有skip、analyze0及Python354PASS/1既有skip，证据绑定3c37b529；c628仅配套版本及iOS构建入口变更，需本次源码冻结比对。全仓verify缺.env未执行，不导入生产秘密。Android正式编译及实际成品验包必须新执行。

## 阶段计时与交接

当次操作时刻以execution及build receipts为准。未发布前渠道仍2204。旧包、备份、设置和CloudFront回退将保存至本次独立目录，未知漂移停止写入。

## 构建返工与证据复用核对

首轮pub get未覆盖本机镜像环境，锁文件发生URL及部分插件版本解析漂移，成品566a34e…042588明确作废、未上传分发。完整diff与恢复CAS见本任务lock-resolution-drift.diff/lock-restoration.json；初步URLs-only判断不完整，已修正。第二轮恢复HEAD原锁SHA79437b4f…e885，官方PUB_HOSTED_URL配合pub get --offline --enforce-lockfile exit0，单一U路径再次freeze/build；新manifest63e3526a…be681。

独立SPEC输入审计1424项旧共享测试输入仅app_config/pubspec版本两文件不同，锁及旧全量日志hash一致。c628比3c仅这两版本文件及iOS integration入口；Android产品代码不变，5632共享测试复用成立。新发布helper30PASS/6PG skip，本机Docker Desktop Linux engine未运行；旧2204真实隔离PG6PASS可复用，因为事务函数逐字相同、PG测试仅身份替换、运行API/worker镜像及所有35容器相同，详细input-audit.json。不存在本次真实PG6PASS的声明。

## 最终候选与发布准备

第二轮2026-10-08T20:21:20左右完成（准确finished_at见delivery/artifact.json），最终APK83110942bytes/SHA b71e83940b7918232baa196501b324737f46d96cd6dab33b1b8ba55a490eecf9；固定75b31/v2/v3单签、16KiB对齐、ARM64/release2205、56WebP/225SVG/双字体、25382smali类语义保持、338原生库/资产逐字不变、六个SQLCipher key/blob导出通过。官方锁7943和1902冻结输入前后一致。SPEC20:22:18接受，QUALITY进行中。

私有顺序分块传输20:21:35–20:23:49，各块SHA匹配；20:25:09完整组装SHA同本地。HK stage /opt/starchat/releases/android2205-20261008-201900，SG stage /home/ec2-user/starchat-android2205-20261008-201900；runtime归档SHA f2d4ffbc32cc05ebdd41adee9cc3e2c72f653030dc8cc5f95f2020676000c941，两端提取同SHA。此时尚未官网/弹窗切换，CloudFront8route前态Deployed。

源码Android元数据回填primary/managed各自原布局，页面反向仅替换Android文件及script标签能恢复原字节；primary54/managed51 NodePASS。首次primary失败2项是旧iOS2194期望与此前已发布2205源码不符，仅修正测试期望，iOS产品字节保持。所有失败/RED/最终GREEN保存source-backfill，未声称首轮通过。


## 发布闭合

最后更新2026-10-08T20:32:03.226959+08:00；20:29:55–20:30:02 PUBLISH_PASS，trace android2205-20261008-201900。CloudFront9route/Deployed、官网页/registry/latest、Android及legacy实际运行路由2205、exact3条审计读回，工作站严格TLS HEAD/小元数据/401均通过。iOS五键/清单/首页及两端min3、schema0095、35运行容器全保持。独立SPEC→QUALITY均接受。

APK SHA b71e83940b7918232baa196501b324737f46d96cd6dab33b1b8ba55a490eecf9，83110942bytes；[官网](https://www.liuhetong888.com/download?platform=android&install=1)。私有0700备份 /opt/starchat/docs/verification/artifacts/2026-10-08/android-2205-201900，旧2204与8旧CDN路由保留。回退先检查现值/审计/文件SHA，再使用备份和SettingService；未知状态不盲目重放。

源码元数据独立提交a0e3a892fffc1cab122c0a054e1af5afb6e0e20f仅4个frontend文件，移动源码与构建c628完全不变；保留已有iOS文档WIP，未main合并/push。git add对已跟踪downloads父目录产生ignore提示，但缓存清单及提交确认准确包含4个自有文件，无遗漏。记录始于20:06:34可靠时刻，至闭合1528.8s；工具并行按区间并集，构建准确起点未知（run标签不是时刻），finished_at20:21:23.859，返工逐段日志保留。

验收A1/A2/A3正式交付完成；真机反馈未执行，A4手机崩溃未定位且未宣称修复。未创建临时隧道；本任务命令全部结束。详细报告见 ../../verification/2026-10-08-android2205-release.md。
