# CI 钱包交接证据归属修复

## 根因与范围

用户报告31项HANDOVER_DEPLOYMENT_EVIDENCE_UNAVAILABLE/503。已确认main 9108a53b的android-ci run34488687785仅Backend & infra gates失败，Flutter analyze/test及Android debug build成功。

test_legacy_handover.handover已经创建完整deployment.json并chmod0600，故“未初始化文件/缺少证据服务”不是已确认根因。handover_deployment.load_deployment在POSIX还要求st_uid==0；普通Linux runner创建的临时文件属于runner，因归属被拒绝。Windows跳过此POSIX条件，解释本地通过、CI失败。泛化ready/timestamp JSON也不满足严格FIELDS契约，不能代替部署证据。

生产loader、服务、鉴权、钱包写入与CI工作流均不改。只在指定测试fixture的模块局部os facade中，按dev/inode匹配模拟该合成文件的root归属；真实文件读取、权限、大小、无符号链接打开、JSON字段、内容哈希、运行来源与时间校验保留。其他文件不变，monkeypatch随测试还原。不让整个CI以root运行，不跳过失败测试。

## 文件

- tests/business_api/wallet/test_legacy_handover.py：fixture显式设置合成证据的所有者模型。
- tests/business_api/wallet/deployment_evidence_fixtures.py：单文件root归属测试适配。
- tests/business_api/wallet/test_handover_deployment_permissions.py：6项边界测试，非root、0644/0660被拒绝，合法文件读取，伪ready JSON及缺失文件被拒绝，其他文件归属不被伪装。

## 验证

证据：docs/verification/artifacts/2026-09-10/handover-ci-ownership/。

- RED：nonroot_posix.py模拟UID1001/0600，原handover第一项复现相同503（red.log）。不修改生产代码。
- GREEN：原受影响六组加权限边界共68项通过（green.log，7.67s）。测试主机仍Windows；这是POSIX边界模拟，非Linux实跑。
- 最终权限测试6项通过；独立审查另跑6项通过，先规格后质量安全无阻塞发现。
- 实际Ubuntu CI run34490176702的Backend & infra gates成功：1815通过、49跳过、0失败（361.62s），原31项失败清零；Infra141、Getui28、移动边界70、UI契约22组件/332页面、OpenAPI、Alembic及Compose检查通过。保留原有环境条件跳过与既有DeprecationWarning，没有为修复增加skip。原失败日志与成功日志摘录分别保存original-ci-excerpt.log、linux-ci-green-excerpt.log。
- Windows scripts/verify.ps1已运行到后端全量，前置仓库/部署策略、模板渲染、Infra141、Getui28、Bot9通过；Ubuntu已完成同套后端全量与后续门禁后，主动停止尚在运行的Windows重复全量，避免重复等待。verify.log是部分记录，不能称Windows完整verify通过；Windows新增权限专项6项已经独立通过。
- CI run34490176702三个任务全部成功：Backend & infra gates、Flutter analyze/test、Android debug build。修复提交d70a16ff已推送main。此次变更不影响已交付2085 APK/IPA，无需重新打包或部署生产。
