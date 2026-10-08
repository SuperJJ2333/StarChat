# Android2205同步阻塞源码候选：00:10+08

状态：**已修复已复现的源码阻塞，未发布，实际手机故障尚未完全闭环。** 官网/弹窗仍为已恢复的Android0.4.37+2206。[任务](../workflow/tasks/2026-10-08-android2205-empty-room-investigation.md)。

## 已证明与修复

- 原2205真实oneShotSync会预迁移响应中每个房间的完整旧main/SENDING/RECOVERY。即使仅有状态/回执、或limited同步马上替换旧main，也要等待旧历史；原源码RED两次等待超时。选择实际需写入的片段，limited main在原事务内reset，独立保留待发送/恢复片段。
- 已有旧迁移与limited替换交叠时，新读取仍等待旧future；RED复现并修复为读取已提交的替换epoch。未让未提交reset成为全局ready。
- 延后保存被替换legacy中的缺正文ID，保持本地搜索可重试；SPEC发现的clear排队竞态经RED复现后在取得事务门内重新校验代际。每页最多256，不改消息正文、密钥、认证或财务状态。

账号绑定服务器证据显示2205响应收到后processing最高300997ms、cache_load最高300000ms；匹配sync13次200/max471ms。它支持调查客户端等待，**不证明这三条源码问题是该手机唯一根因，不证明手机OOM或没有OOM**。未取得实际手机数据库/堆栈。

## 实际验证

| 门禁 | 结果与范围 |
| --- | --- |
| 新增回归 | 8PASS：多房间、pending/recovery、缺正文ID、并发旧迁移、事务回滚、SQLCipher半迁移重开512ID、clear排队、真实恢复缓存账号与首轮sync |
| Flutter全量 | 5638PASS/9skip/1FAIL；唯一旧断言禁止仓库内临时目录，与AGENTS命名验证目录规则冲突。测试路径断言修复后该文件79PASS；产品输入未改，按影响规则复用其他5638项证据。没有声称原全量run是exit0 |
| 移动边界 | 364PASS/23skip，exit0 |
| analyze | 最终No issues found，exit0 |
| Android ARM64 release/AOT | 正常生成流程重试exit0，78.9MB源APK仅编译中间物，不是交付包。首轮--no-pub沿用测试插件注册而编译失败，已按工作流重新生成。锁文件无变化；既有KGP/旧API插件警告未改，不是编译错误 |
| 独立审查 | SPEC后QUALITY均PASS，明确只验收有界源码修复；不替代Android运行/手机证明 |

Flutter3.44.9/Dart3.12.2/Java17.0.20，基线c628fe2e6706000cd721d6118c3e8ef8d372d7e2；[输入SHA及结果](artifacts/2026-10-08/android2205-empty-room-investigation/source-candidate-evidence.json)。[全量日志](artifacts/2026-10-08/android2205-empty-room-investigation/flutter-full.log)、[8条新回归](artifacts/2026-10-08/android2205-empty-room-investigation/upgrade-eight-green.log)、[Android编译](artifacts/2026-10-08/android2205-empty-room-investigation/android-source-compile-retry.log)。

## 下一步与实际缺口

源码保存在attached managed工作树`C:/Users/Administrator/.codex/worktrees/android2205-sync-deadlock/StarChat`。未合并、推送、发布或触发新更新弹窗。原生ARM64编译通过不等于Android SQLCipher/isolate实际运行：adb无设备、没有AVD，用户此前无法USB连接这一事实未改变。

新版本发布前先验证并实现**2206回升兼容**：2206恢复旧格式写入后，2205 ready的timeline/search索引可能过时；不能直接把本候选重新发布覆盖。随后验收保留原账号缓存的Android首次启动、切房间/同步及原故障。`.env`缺失，未用生产秘密强行运行完整verify.ps1；已执行适用移动门禁，服务端没有代码/配置变更。

## 2026-10-09 00:43+08 回退后再升级兼容修复

所有权追加：SDK matrix_sdk_database/timeline_id_store/retained_search_store与新legacy_rollback_rollforward_test。真实SQLCipher夹具复现2205 ready索引→2206旧格式新增/修改/移除消息→候选再升级：旧timeline漏新ID，旧search保留已移除记录；rollforward-red.log退出1。兼容修复仅添加本地元数据列和索引，在Box缓存开启前原子消费2206回退完成标记，旧epoch失效；记录按需分批准备，搜索按捕获revision退休旧索引，保留随后新增项与删除标记。不改消息正文、旧JSON、账号和密钥。4条升级用例包含ready、copying、事务中断与重试，真实SQLCipher全部PASS。

00:34专项重跑65PASS/exit0，覆盖原同步/索引与新增回升。前一轮64PASS/1FAIL是测试ObservedSql适配器无直接execute；将新表列包含于CREATE、旧表ALTER使用已有batch接口后通过，未删除/弱化分页测试。全量最终00:42完成5644PASS/9skip/exit0（6m24s），移动边界364PASS/23skip/exit0（62.34s），analyze无问题/exit0（13.5s）。证据：rollforward-focused-retry.log、flutter-full-rollforward.log、mobile-boundary-rollforward.log、analyze-rollforward.log。规格审查随后质量审查PASS，最终marker-absent/批DDL补审PASS。

回升兼容源码门禁已闭合；Android最终源编译进行中。仍没有连接设备或AVD，不能以Windows SQLCipher测试/ARM64编译替代实际Android运行和用户数据覆盖升级。稳定2206生产分发未改；不发布当前2205源中间包。

2026-10-09 00:45+08：最终兼容候选 Android ARM64 release/AOT编译exit0，Gradle71.8s。源包仍2205，仅中间物未分发。下一步准备独立递增版本的固定签名候选，保留稳定2206渠道；实际手机覆盖升级/首次sync/空列表和入房验收仍未执行。
