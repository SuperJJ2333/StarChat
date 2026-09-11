# main 集成、跳板部署与 Mi 6 Debug

## 恢复入口

- 用户授权：合并其余分支到main、push、跳板部署生产、Debug覆盖安装Mi6；用户自测。2026-09-11本轮授权取代先前任务的禁止发布范围。
- 计划：../../superpowers/plans/2026-09-11-integrate-deploy-mi6.md。
- 角色：Astra主审；既有显式gpt-5.6-terra执行者profile分支审计、viewer设备/签名预检。文件所有权先只读，后逐批声明。
- 开始：2026-09-11约22:05+08:00，精确首工具时间未另记录。
- 状态：已完成全部本地分支合并与 main 推送、跳板生产部署、Mi 6 Debug2088保留数据安装；用户真机功能验收待进行。
- 下一步：用户打开 Mi 6 上的畅聊测试；有反馈时沿本记录定位，不自动重建或再次部署。
- 证据：主工作区 docs/verification/artifacts/2026-09-11/integrate-deploy-mi6/；finance原证据保留在performance工作树。

## 生产初读

2026-09-11T14:07:38Z，经 scripts/starchat-server.ps1 / jumper 成功：API镜像fea5b9417e5c、worker7e0e9ffc64c6、synapse与sync worker fd9d961a472a；均healthy。后续取完整digest、Compose层和schema再冻结，不能凭此短ID直接覆盖。

## 集成审查（22:36 +08）

- 财务已审清单提交 035bf7e3；performance 合并 64455ec9，L07 合并 2202c9f5。所有本地分支已成为集成候选祖先。
- Astra 复核 main/session_store/reconciler/probe/startup gate 实际调用链，保留既有 052e600b 空 SDK 兼容路径，真实身份不匹配仍失败关闭。补充失败时禁止建库及保留失败删除槽枚举入口；ADR 完成领域与 Quality/Security 评审。
- 实际定向证据：安装相关154、金融/启动94、门禁4项通过，12文件分析通过。门禁集成验证采用真实 reconciler 与内存安全存储，验证启动回调阻断/重试；未进行真实设备数据库创建测试。
- admin-completion 及其他工作树未提交内容独立保留，不把未提交钱包/鉴权改动当作分支提交发布；未删除任何分支/工作树。
- 生产候选仅8个 API 源文件和13个设计演示静态文件。10个相关钱包文件与线上已完全一致；不重建 worker/Synapse/网关，不执行数据库迁移。
- 候选镜像 a397ecd9a887d0c1119e06b9264ebeddfebd491a38d061fb52ba1dcb56c3817b；隔离 Linux/PG 金融门禁44通过（21.16秒）。最初缺少 pytest-asyncio 的环境失败在补齐隔离测试依赖后复测通过，生产镜像未增加测试依赖。
## 发布准备（22:41 +08）

- 经跳板执行 prepare，生产尚未切换。私有备份：`/opt/starchat/releases/integrate-finance-20260911/backup/`，dump 4,891,273 字节，SHA256 `acf3a0991d222e442fec3db9424ecc18edf3965f94a71f0a66b648bb62099e6c`。
- 实际在 `--network none`、无端口、tmpfs PG16.9 容器中完整恢复，版本 `0064_admin_deposit_repairs`，退出0，临时容器已清理。未下载生产数据。
- 发布/回退脚本经 Astra 实际审查返工，10项模拟普通与 Python -O 均通过；恢复脚本3项均通过。完整配置与备份哈希、已知镜像、其他容器身份、静态漂移均检查。每个静态文件原子替换，不宣称整个13文件目录为单次原子发布，存在极短混合版本窗口。
- 21个部署源文件已与最终集成工作树逐字节核对，全部匹配。最初以规范化换行比较导致不匹配，改用精确文件字节后通过；未改候选内容。

## 最终集成门禁（22:43 +08）

- 版本 0.3.84+2088；Debug 构建名称覆盖 0.3.84-debug。候选 pytest 版本契约2通过；全量 Flutter analyze 通过。最初直接执行 pytest 文件没有运行用例，已标为无效初次证据，以上为真正 pytest 结果。
- Flutter 最终2344通过/29既有钱包失败，失败集合与 finance 基线一致。首次多出的 SQLite14 为 Windows 长路径夹具问题；仅缩短测试证据目录，单项及全量复测通过，未改产品数据库逻辑。
- 全仓无关失败仍未解决，不宣称全仓绿；依据工作流复用此前金融/契约/安全门禁，生产候选 Linux/PG44通过。


## Git 与生产已完成（22:48 +08）

- main 已快进并正常推送，远端核对 6be555723acc1cac0d790372e8f45fef1c0c0f36；全部其他本地分支均为祖先。没有 force push、删除分支或合并未提交后台改动。
- main 原有30路径逐字节恢复（含原混合换行），pubspec.lock 原有编辑与 stash 差异逐项一致，同时保留集成依赖新增。保留安全 stash，未提交任何用户既有改动。
- 22:45通过跳板仅重建 business-api；最终实际镜像 sha256:a397ecd9a887d0c1119e06b9264ebeddfebd491a38d061fb52ba1dcb56c3817b。13静态文件更新并校验；design-demo 是 frontend 的既有链接，清单中26路径对应13实体，没有额外文件变更。
- 服务器与工作站TLS验收：健康JSON200且ok/database ready，账单未登录401，公网tokens.css SHA匹配。8 API运行文件与13静态源文件逐字节匹配，其他容器ID保持，schema仍0064_admin_deposit_repairs。发布后344行日志中ERROR/CRITICAL/Traceback计数0（观察窗口有限）。
- 工作站使用独立127.0.0.1:18947跳板SOCKS，验证后已终止，端口无监听。未变更系统代理。
- Android 首次包被门禁拒绝：继承 parallelDebug=true，生成 com.liuhetong.mobile.debug。未安装此包；仅交付脚本显式 false 重建正确包名，产品源代码未变。


## Android 包名环境根因（22:57 +08）

环境变量 false 被用户级 Gradle 的 chatflowParallelDebug=true 覆盖，第二次候选在源码 aapt 预检即被拒绝，没有重建/安装。读取 Flutter 工具源码确认 android-project-arg 转成 Gradle -P；以 -PchatflowParallelDebug=false 实际预检成功（1分51秒）。交付脚本改用显式 --android-project-arg=chatflowParallelDebug=false，未修改用户全局配置或产品源码，正在最终构建。原始失败证据保留，第三次候选路径 android-delivery-final。


## 完成交付（23:01 +08）

最终包 bd7c1e97d2753fe41186145a340a74e4ef3d7890c41f71e0a8a7c7c70de0aebb，com.liuhetong.mobile / 0.3.84-debug /2088，固定75b31签名。源码103.5秒，重建语义校验通过，23:00:48 install-r成功。设备首次安装时间保持00:42:05，回读实际APK字节哈希一致。未真机功能测试。完整记录：[交付报告](../../verification/2026-09-11-integrate-deploy-mi6.md)。所有R1–R6交付步骤完成；既有测试失败与用户验收缺口按报告保留。
