# 客服充值提现生产发布与 Mi 6 交付

2026-09-23 15:00 +08：用户授权的配套生产部署与Mi6安装已完成。源码398ffbd5；APK同步pubspec和AppConfig版本标识为0.4.2+2161，未改变已验证业务代码。真实收款、出款、短信和客服首次开通由用户实际操作验收，本次未代做。

## 验收结果

| ID | 结果 |
|---|---|
| S1 数据库 | 生产备份在无外网隔离容器恢复，0083→0087通过；130张原有表、214941行的原字段摘要完全一致。再次备份后生产升级，读回唯一head0087_support_payout_workflow |
| S2 API/worker | 基于实际线上镜像增量覆盖38个文件；349个源码文件逐项SHA核对。API/worker健康、零重启、无Traceback/maintenance_failed；其余21个容器身份及启动时间未变 |
| S3 后台 | 11个后台JS/CSS按前态哈希校验后发布；保留原静态文件备份。服务器和工作站HTTPS返回资源200且SHA一致；no-store缓存头；浏览器实际渲染管理员、客服及首次开通入口 |
| A1 APK | 0.4.2+2161 Debug，单ARM64；Apktool2.12.1重建、zipalign36、固定签名及独立重解包全部通过 |
| A2 Mi6 | 14:59:10保留数据覆盖安装Success；读回2161、固定签名及APK完整SHA一致；MainActivity Status: ok，进程存在，firstInstallTime保留 |

两侧公网health/ready为JSON200；官方收款信息、客服队列/通知、提现处理、安全验证和汇率接口无授权返回401。此证据证明路由存在且拒绝未授权访问，不等同于真实资金操作成功。

## 发布身份

- API `starchat-business-api:support-order-20260923`：`sha256:e537ee511d5eb2b3ffb97ba30a9c1a30969f05e5965531773389140e7cc83738`。
- Worker `starchat-business-worker:support-order-20260923`：`sha256:15f7c551aed7a169e9059b550944af0c149c605bf0f25e596cbc84e6e9e8dcca`。
- 实际Compose：`/opt/starchat/releases/support-order-20260923/candidate-api-private.json`及`candidate-worker-private.json`，使用固定image ID；配置沿用上线前现场。
- 人工充值、提现申请及执行独立开关为true；自动充值false，用户兑换closed=true；原group-transfer协调开关保持false。没有把总real_funds=false误判为独立人工开关关闭，也未改变既有保留配置。
- APK包名`com.liuhetong.mobile`；SHA256 `d4526bb03b5c3e0d490a7214e53132a8b54774db0968e6e25ac8958763b8d185`，145412395字节。
- 固定签名SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。

## 证据与回退

本地工件：`artifacts/2026-09-23/support-order-release/`，含baseline、候选源码清单、恢复前后结果、镜像来源核对、公网两侧结果、运行检查及android工件。详见[Android报告](2026-09-23-support-order-android.md)。私密Compose、环境及数据库备份仅保留服务器0700发布目录，未下载或入Git。隔离恢复容器和临时卷已删除，宿主机备份保留。

现场回退记录为同目录`rollback-api-private.json`、`rollback-worker-private.json`及`frontend-backup/`；需要回退时先停止新增业务并核对新流程在途订单，再按冻结Compose恢复相关服务与静态。不得盲目让旧流程处理新订单，不降级schema、不还原整库覆盖新交易，不自动释放不确定出款或重复发币。

复用同源完整verify exit0（后端2616/65、mobile108/1）、Flutter3875、analyze0、frontend265及独立PG并发/资金专项；本轮补做生产备份恢复、Linux候选装配、实际迁移、两侧公网与固定签名构建/真机安装。跳过项含义未变。本次未改官网正式Android下载设置、iOS、最低支持版本或用户更新弹窗。

## 时间与限制

14:40开始，约14:48完成服务切换，14:50完成双侧公网/后台入口检查，14:51完成首轮设备读回，14:59完成2161覆盖安装。构建与服务器工作并行，首次源码构建46.7秒，修正后27.5秒，不将并行阶段相加。15:00完成最终记录。

客服需使用自己的既有APP身份首次开通并完成资金操作验证。部署没有替客服跳过验证码或创建生产会话。用户侧参考估算优先展示，实际到账仍以客服核实后的权威结算为准；真实充值/提现流程及视觉体验待用户反馈。

## 版本门禁返工

2160曾成功安装，但收尾test_app_build_contract发现AppConfig备用标识仍2159（1failed/15passed）。修正两个版本来源至2161，保留2160全部记录；版本门禁16通过、Flutter版本/更新专项31通过、app_config分析无问题。2161重新完整构建、固定签名重建及独立验包后覆盖安装。未通过改测试或隐藏失败绕过门禁；生产镜像没有因纯客户端版本修复再次发布。最终APK位于 `artifacts/2026-09-23/support-order-release/android-2161/final.apk`。
