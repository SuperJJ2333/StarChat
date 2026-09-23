# 网络交付首批执行计划

依据：[设计](../specs/2026-09-23-network-delivery-design.md)，用户已批准上一轮架构重点。工作树 .worktrees/network-delivery，基线f43ec78a。所有新增文件独占，不修改既有业务或Flutter。

1. AWS基础设施：infra/aws/network-delivery/{public-media,regional-foundation}.json、该目录README.md、tests/infra/test_network_delivery_aws.py。先测试私有桶/OAC/TLS/无公开写入、两AZ/私有子网/限定后端入口等关键性质失败，再实现资源模板并用CloudFormation schema lint验证。资源实际创建须有AWS身份、证书和预算输入。
2. 测点工具：scripts/network_probe.py、tests/infra/test_network_probe.py、docs/runbooks/network-probes.md。测试URL/次数/输出边界、失败分母、重定向/代理与各阶段计时，然后实现CLI和本地受控fixture测试。真实大陆/东南亚运营商执行待测点接入。
3. TURN：scripts/render_regional_turn.py、infra/coturn/regional-compose.yaml、tests/infra/test_regional_turn.py、docs/runbooks/regional-turn.md。红绿覆盖注入/弱secret拒绝、权限、区域host网络/端口、证书、relay范围、共享secret不进stdout。使用已固定版本镜像验证配置/帮助，无生产凭据。
4. 整合：docs/runbooks/network-rollout.md、docs/workflow/tasks/2026-09-23-network-delivery.md、docs/verification/2026-09-23-network-delivery.md。记录AWS接入与预算、证据缺口、逐阶段命令/回滚、源码hash与真实测试结果。主目录按新文件回填，不覆盖并行改动。

门禁：先infra基线；逐批红绿；最终infra全量、仓库/部署/模板policy、配置渲染/Compose和新工具真实CLI检查，CloudFormation官方schema lint。预检verify.ps1；业务与移动代码、锁文件不变时按交付工作流复用相同基线证据，不重复长业务/Flutter全量。不得用模板/静态测试冒充AWS部署验收。
