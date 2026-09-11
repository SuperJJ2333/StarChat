# 2026-09-11 main 集成、生产部署与 Mi 6 Debug

## 授权与范围

用户明确授权合并其余分支到 main、正常 push、通过跳板部署生产，并将 Debug 安装 Mi 6 由用户测试。Astra 负责实际差异、调用链、测试证据与发布审查；实际使用 gpt-5.6-terra 的执行者负责修复、自动化和构建脚本。未对真机进行功能或资金操作测试。

## Git 与现有改动

源代码候选：`6be555723acc1cac0d790372e8f45fef1c0c0f36`。main 已正常推送，远端 SHA 已核对；所有其余本地分支的提交均为 main 祖先。finance 提交 `035bf7e3`，performance 合并 `64455ec9`，L07 合并 `2202c9f5`。

主工作区原有30路径恢复为原始 SHA256；pubspec.lock 保留原有逐项编辑，同时保留集成依赖新增。安全 stash 保留。其他工作树未提交的后台、钱包、鉴权等改动未擅自纳入发布；未删除分支或工作树、未强推或回退代码。

L07 合并时发现安装检查失败后继续建库及部分删除失败丢失账号槽枚举入口，补充启动门禁/安全重试并完成领域与 Quality/Security 评审。保留既有空 SDK 绑定兼容逻辑，真实身份不匹配仍失败关闭。

## 自动化证据

| 验证 | 结果 |
| --- | --- |
| 安装/会话连续性 | 154 通过 |
| 金融/启动组合 | 94 通过 |
| 启动门禁 | 4 通过 |
| 候选版本契约 | pytest 2 通过 |
| Flutter 全量 | 2344 通过、29 既有钱包失败，与上一候选失败集合一致 |
| Flutter 全量 analyze | 无问题，退出0 |
| 候选 Linux 隔离 PostgreSQL 金融门禁 | 44 通过，无跳过 |
| 发布守卫模拟 | 普通与 Python -O 各10通过 |
| 隔离恢复脚本模拟 | 普通与 Python -O 各3通过 |

初次全量增加的 SQLite14 由 Windows 测试数据库路径过长导致，仅缩短测试临时目录；单项与全量复测证实已解决。最初直接运行 pytest 文件未执行用例，已弃用该证据，采用候选工作树中真正 pytest 的2通过结果。没有弱化业务断言或将既有失败标为通过。

此前全仓后端/Node 等既有失败仍见[金融审查记录](2026-09-11-finance-chat-review.md)，未因发布而宣称全仓通过。真机、多端、断网交互和 iOS 原生行为仍由后续验收覆盖。

## 生产

通过 `scripts/starchat-server.ps1` 的 `ssh -J jumper -p 23421` 通道操作，保留主机密钥及 HTTPS 证书校验。

- 实际候选镜像：`sha256:a397ecd9a887d0c1119e06b9264ebeddfebd491a38d061fb52ba1dcb56c3817b`。
- 旧镜像：`sha256:fea5b9417e5c2316ea711fccb09981fb058b3ea13546a6c54e8c9524ddef4152`。
- payload SHA256：`426fa2507e7cf3e1ebe6723f545447d4e9534f3b56a977cbf044507a6d19592c`。
- 仅覆盖8个金融 API 文件，重建 business-api；13个前端静态实体更新。`design-demo` 是 `frontend` 的既有链接，文件审计的26路径对应13实体。
- 钱包另外10个相关源文件与线上已有内容一致；worker、Synapse、个推、网关等容器ID保持不变。
- schema：`0064_admin_deposit_repairs`，没有执行数据库迁移。
- 22:45完成切换；服务器和工作站 HTTPS 健康JSON200、账单未登录401、公网资源SHA均通过。8个运行源文件和13个静态文件逐字节符合清单；发布后检查344行日志，ERROR/CRITICAL/Traceback计数0，仅代表该观察窗口。
- 临时恢复数据库/测试容器和工作站SOCKS均已清理。未输出密钥、生产配置或资金数据。

### 备份与回退

服务器私有目录：`/opt/starchat/releases/integrate-finance-20260911/backup/`。数据库 dump 4,891,273字节，SHA256 `acf3a0991d222e442fec3db9424ecc18edf3965f94a71f0a66b648bb62099e6c`。已在无网络、无端口、tmpfs PostgreSQL16.9实例完整恢复，并验证schema；备份未下载到工作站。

如需回退，先重新核对线上没有后续发布，经跳板执行：

```text
python3 /opt/starchat/releases/integrate-finance-20260911/deploy_candidate.py rollback
```

脚本拒绝未知镜像/静态漂移，恢复冻结的旧API与静态文件，不执行数据库降级。单文件原子替换；13文件整体存在极短混合版本窗口，不宣称整个目录一次性原子切换。

## Android 交付状态

已于23:00:48成功保留数据覆盖安装到 Mi 6（cbd0156b），未启动功能/资金测试。用户可直接打开畅聊进行验收。

- 包名 `com.liuhetong.mobile`；`0.3.84-debug / 2088`；ARM64、debuggable。
- APK 143,724,843字节；SHA256 `bd7c1e97d2753fe41186145a340a74e4ef3d7890c41f71e0a8a7c7c70de0aebb`。
- 固定用户测试签名 SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，与安装前包一致；v2/v3校验通过。
- 正常 pub get 后源码构建，再按 Apktool2.12.1 重建、zipalign36、固定签名；27,242个类语义及339个原生/资产文件不变，清单语义一致。
- 最终源码构建103.5秒；pubspec.lock不变，编译源代码与已推送的6be55572一致。
- 两个错误 `.debug` 包名候选被校验拒绝，均未安装。根因是用户级Gradle属性覆盖环境变量；通过经预检的 `--android-project-arg=chatflowParallelDebug=false` 解决，未改用户全局设置或直接篡改清单。
- `adb -s cbd0156b install -r` 返回Success；回读包版本2088，拉回实际base.apk的SHA与交付包完全一致。首次安装时间仍为2026-09-11 00:42:05，未卸载、清数据或降级。

[最终 APK](artifacts/2026-09-11/integrate-deploy-mi6/android-delivery-final/debug-2088/final.apk) · [构建汇总](artifacts/2026-09-11/integrate-deploy-mi6/android-delivery-final-summary.json) · [安装日志](artifacts/2026-09-11/integrate-deploy-mi6/mi6-install-2088.log)。此 Debug 只安装用户真机，没有替换正式下载包或修改官方更新设置。

## 证据入口与耗时

[任务记录](../workflow/tasks/2026-09-11-integrate-deploy-mi6.md) · [计划](../superpowers/plans/2026-09-11-integrate-deploy-mi6.md)。完整非Git日志与包位于 `docs/verification/artifacts/2026-09-11/integrate-deploy-mi6/`。

开始约22:05；22:36完成合并审查；22:41备份隔离恢复；22:43集成门禁完成；22:45生产切换。Android首次源码构建170.9秒；包名环境纠正后的构建与重建耗时见最终交付日志。阶段存在并行，不能简单相加。

23:01完成设备身份与实际包字节核验，结束交付。原生iOS与用户交互/性能验收未执行；29个钱包基线测试失败仍保留，不能据此次安装宣称全部功能验收通过。
