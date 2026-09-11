# main 集成、跳板部署与 Mi 6 Debug

## 恢复入口

- 用户授权：合并其余分支到main、push、跳板部署生产、Debug覆盖安装Mi6；用户自测。2026-09-11本轮授权取代先前任务的禁止发布范围。
- 计划：../../superpowers/plans/2026-09-11-integrate-deploy-mi6.md。
- 角色：Astra主审；既有显式gpt-5.6-terra执行者profile分支审计、viewer设备/签名预检。文件所有权先只读，后逐批声明。
- 开始：2026-09-11约22:05+08:00，精确首工具时间未另记录。
- 状态：集成候选已纳入全部本地分支，2202c9f5；正在完成版本 2088 与集成验证。main 本地改动已记录31项哈希，尚未切换。
- 下一步：固定版本、验证并保护 main 本地改动后快进/push；生产备份隔离恢复通过后切换；最终 Debug 重建签名并安装 Mi 6。
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
