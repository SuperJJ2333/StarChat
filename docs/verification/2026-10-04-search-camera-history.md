# 搜索、相机与自动历史恢复交付

客户端源码 `7e7e9a2a5fcb255ed59af21e087aeebcc503c11d`，版本 `0.4.29+2198`。搜索稳定进度与旧消息定位、荣耀系统相机、服务器托管归档/自动恢复及固定72小时密文补齐通过有序规格/领域及质量安全审查。详细授权、RED/GREEN、返工和阶段时间见[任务记录](../workflow/tasks/2026-10-03-search-camera-history.md)。服务器托管能力和边界见[ADR](../adr/2026-10-04-server-custodied-matrix-recovery.md)。

## 源码与平台验证

| 门禁 | 实际结果 |
| --- | --- |
| 整套 Flutter | 5393 PASS、9 skip，exit0；实际运行于8d2c26cf，之后只有两文件版本变更，独立审查接受影响复用 |
| Flutter analyze | 0 issues；版本契约另有3 PASS |
| 移动 Python | 307 PASS、23 skip |
| 前端/契约 | 522 PASS，33组件/528屏契约通过，四个搜索状态浏览器截图 |
| 搜索与相机专项 | 搜索224+115；相机71 Dart/8 native；荣耀真机尚未反馈 |
| 实际恢复 | 公共wire新broker设备/fresh SQLite真实Megolm解密与篡改负例1 PASS；实际SQLCipher旧加密库保留恢复2 PASS |
| 灾备 | 实际PG备份恢复、混合封装key中断、丢失主凭据/主机key后独立CurrentUser DPAPI恢复，3个原SDK归档可恢复 |
| iOS同源 | [37183887834](https://github.com/SuperJJ2333/StarChat/actions/runs/37183887834)完整原生编译、iPhone15 iOS18/iOS26三个job success，15:13:25+08完成 |

完整Flutter首次5383PASS/9skip/7fail的日志与后续修复保留，未豁免失败。整仓verify.ps1受既有local.env前置限制，未导入生产秘密，也未称整仓全部通过。Android固定构建工具的KGP未来兼容提示及Java测试说明已记录，不称构建无警告。wire的Business网络JWT authority明确为隔离synthetic；实际Business/PG authority验证是另外的门禁，不能合称真实用户生产端到端。

## Android调试交付

最终包：[final.apk](artifacts/2026-10-03/search-camera-history/android-debug/run-20261004-144800/final.apk)，135737571字节，SHA256 `6fa1801347e38aee8abe3ae98ff7beaf644de396dd3a0e702156af124a5ddbe6`。

标准x86_64 debug source build→Apktool2.12.1完整DEX/资源/manifest常规重建→zipalign36-P16→稳定P12签名→签后语义/26DEX/27351smali类/474资源/338native及Flutter assets/lock/1864输入冻结检查全部PASS。稳定签名SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，v2/v3单签名；独立最终验包PASS→PASS。

2026-10-04 15:54:48+08以 `adb install -r` 安装emulator-5556，UID10090及首次安装时间2026-09-26 04:06:20保留，版本0.4.29/2198。启动Status ok，超过120秒同进程存活、0 fatal签名，见[smoke](artifacts/2026-10-03/search-camera-history/task-4-debug-smoke-2198.json)。

## 服务端实际启用

最终helper `f24380ccf8b62565aaa6206109062d6a01688e3bef265bb8cc0922f06f8702b5` 通过有序独立复审、25模型测试及真实Nginx有效/无效配置控制。实际15组完整Compose/运行投影等价、续期角色guard、provider权限和语法check PASS。private release文件清单SHA `a57775a5270fd3fe658f40cd029339fb707da053d4aa3b202607fcc94ffafaa1`，审批receipt绑定八项真实验收证据。私有原配置/数据库备份/凭据不复制进仓库。

16:01:59–16:03:02+08关闭状态部署/验证PASS，随后启用。16:04:13首次即时检查exit1，保留原日志；网关在新main于16:04:07启动期间记录原生versions502。随后完整verify和稳定状态deploy均PASS，未更改候选或重复重建已匹配容器。实际worker进程/8081监听、模块导入/无启动错误、main UID991、只读主密钥挂载/main-only、完整配置hash及原生login/versions/sync控制通过。公开恢复401/no-store，私有入口403，8类TRACE405不反射，access/error无哨兵，普通GET日志控制保留。

生产执行有序独立审查PASS→PASS，报告SHA256 `8994ca18390e2ab02e2e5ac6ca97c36b38011132c19b8b15f407f622e21d635b`。工作站响应断言另存task-4-workstation-response-assertions.json。

实际API `sha256:2fd052541347b0a6d01f2e7269ab4c4ffb82dd57fa01aa1b893b0b2b56a81568`，Synapse main/worker `sha256:449fef97b26ba00d62b7c128bdff1e440a127349f89fedf0e6556721c3aa2876`；business-worker、Getui及冻结其他容器身份保持。实际API/main/sync健康、0restart，gateway同固定镜像。工作站经既有jumper SOCKS、保留证书/SNI校验：API ready200且JSON ready、Matrix versions200、恢复401/no-store、private403。证据见[运行状态](artifacts/2026-10-03/search-camera-history/task-4-production-runtime-observed.json)及[公网控制](artifacts/2026-10-03/search-camera-history/task-4-workstation-public-final.json)。扩展恢复表/原生schema92/media保持，真实provider与独立灾备保留；回退恢复冻结镜像和配置，保留恢复数据/审计/凭据，不执行downgrade。

## 交付边界

16:07:19+08只读线上设置仍Android0.4.27/2196、iOS0.4.25/2194。本轮交付2198调试包及服务端启用，没有发布正式移动版本、更新弹窗或新IPA。真实荣耀/MagicOS8、新手机/账户切换恢复、K80长时性能仍待反馈；未备份且彻底丢失的历史密钥无法重建。托管模式使服务器具备恢复历史密钥能力，不能声称服务器无法解密托管历史。

主分支整合保留1372个无关trackedWIP内容哈希及原索引新增发布记录；只清理本任务资源。正式主分支推送与资源清理的最终时间/hash由任务记录补充。
