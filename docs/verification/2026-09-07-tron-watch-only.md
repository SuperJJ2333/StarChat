# TRON真实只读监控及隔离验证

用户授权三阶段方案后补充“尚未准备，先完成只读监控和隔离验证”。因此本次只实现第一阶段观察器，并回归已有资金关闭/审批/幂等隔离逻辑。未生成真实专属地址，未部署签名或开放资金。

## 实现与审阅

- 独立TronGrid只读adapter：官方USDT合约的Base58Check与收据hex一致性、成功固化收据、真实日志序号、整数金额、禁止重定向、分页游标循环/缺失保护、扫描总时限60秒。
- 独立SQLite观察存储：原子水位、重启去重、事件冲突整窗回滚、失败心跳、历史/实时转出分开记录。水位为单来源遍历水位，不是完整链索引证明。
- 两次稳定、对应截点之间才输出SOURCE_MATCHED；不能对应时RECONCILIATION_UNVERIFIED。余额差异记录为BALANCE_DISCREPANCY。SOURCE_MATCHED不代表业务账本对账或可自动入账。
- 非root独立容器，无主业务数据库/签名材料、无公开端口、只读源码及根文件系统、受限数据目录。镜像继承环境及entrypoint已在服务器核对，无业务凭据。
- 领域审阅后Quality/Security审阅通过，两位审阅分别独立运行53项TRON测试通过。审阅发现的覆盖起点字段、单来源表述、历史转出区分、余额日志脱敏均已处理。

## 测试证据

- Reader35项、Observer15项、CLI3项，共53项通过。红绿证据见工件目录；初始契约拼写错误经独立Base58Check/hex断言修复，并完成主网真实读取核验。
- 现有钱包安全/托管契约/API门禁隔离回归31项通过；此结果不替代真实签名、双源、控制权或链上转账验收。
- 真实只读查询：近30天2条Transfer记录，均通过官方合约及固化收据核验；可读取余额，首次观察区块在推进所以stable_balance=false，没有虚报对账成功。没有将真实地址或流水详情写入仓库证据。
- Ruff检查通过。全仓库回归654通过、30跳过，迁移、OpenAPI、Compose与UI契约检查PASS；保留3条既有Starlette/httpx及Getui Pydantic弃用提示。部署目录权限修正后，最终专项54项全部通过（含新增Compose回归），Ruff通过。源码未随部署修正改变，只修改独立挂载目录和模块启动路径。

## 运维边界

第一批覆盖近30天；更早历史未回补。索引延迟超过重叠窗仍可能造成漏观察，单来源不足以证明资金事实完整；未来启用充值前需要独立双源和更强区块级完整性验收。运行健康与caught_up分开记录。外部通知尚未配置，异常写入和日志不能称为告警已送达。

运行手册：[tron-watch-only.md](../runbooks/tron-watch-only.md)。工件：`docs/verification/artifacts/2026-09-07/tron-wallet/`。后续阶段等待受控签名基础设施、审批人员和相应生产验收；本次不修改主钱包资金开关。

## 实际部署及恢复

独立服务已部署到服务器，项目starchat-tron-watch，非root UID10001，运行导入路径/opt/tron/__init__.py已验证。初次启动发现旧业务源码目录不允许非root遍历，导致导入失败；新增回归测试确认失败后改为独立/opt/tron只读挂载，安全复核通过，没有提高权限或修改主业务镜像。

近30天回补2条记录：1条转入、1条历史未匹配转出。实际重启后保留2条且未重复添加，水位继续推进；后续摘要caught_up=true，成功扫描时距当前固化遍历水位约110秒。当前实际余额截点仍为RECONCILIATION_UNVERIFIED，不能宣称生产对账已匹配。

所有原业务容器ID保持不变。真实资金开关未修改；当前API仍可用。具体证据：[部署](artifacts/2026-09-07/tron-wallet/deployment-result.json)、[重启验证](artifacts/2026-09-07/tron-wallet/restart-verification.json)、[镜像凭据隔离](artifacts/2026-09-07/tron-wallet/runtime-image-check.json)。记录的近30天范围是单来源返回并已核验收据的观察范围，不保证索引器没有遗漏。

后续稳定性复查：累计2个稳定余额快照、1次SOURCE_MATCHED、3次RECONCILIATION_UNVERIFIED；最近一轮仍可能因区块推进而未验证。该实际匹配仅证明同来源稳定窗口一致，不扩大为独立双源或业务账本对账。证据live-stability-check.json。
