# ADR-0007：移动端 Matrix 会话连续性与 Megolm 密钥恢复

**状态：** 产品设计已批准；Domain 与 Quality/Security 评审待完成

**日期：** 2026-08-25

## 背景

当前启动流程在 Business 会话不存在或失效时可能重置 Matrix 本地存储。即使用户只是普通退出并在同一手机重新登录，也可能删除 SQLCipher 数据库、数据库密钥、设备 ID和 Olm/Megolm 状态，造成历史密文无法解密。

现有“加密备份”只创建 SSSS 密钥，没有完整创建、上传和恢复在线 Megolm 房间密钥备份，也没有启用标准可信设备秘密请求。统一占位文案“消息尚未解密”无法区分正在恢复、确实缺钥和密钥损坏。

## 决策

1. Business 登录状态与本机 Matrix 账号绑定分离。普通退出清除 Business 会话并暂停 Matrix 同步，但保留 MXID 绑定、Matrix SQLCipher 数据库、数据库密钥、Matrix Access Token、设备 ID和全部本地加密状态。
2. APP 重启发现 Business 会话不存在但 Matrix 数据存在时进入登录页，不重置 Matrix。
3. 同账号重新登录复用原 Matrix 设备。Token 有效时直接同步；soft logout 或 Token 明确失效时，使用一次性 Matrix Login Token和原设备 ID重新认证，只替换凭证，不清除数据库或 Olm 账号。
4. 只有登录令牌返回不同 MXID且用户确认切换，或用户二次确认“清除本机聊天数据”时，才删除 Matrix 数据库、SQLCipher 密钥、SSSS 恢复密钥缓存和绑定记录。
5. 使用 Matrix SSSS、交叉签名和 `m.megolm_backup.v1.curve25519-aes-sha2` 创建真正的在线 Megolm 备份；已有和新增的入站会话均加密上传。
6. SSSS 恢复密钥自动保存在 Android Keystore / iOS Keychain，并允许用户主动导出；Business API和 Synapse不得取得其明文。
7. 新设备优先使用 Matrix SAS/二维码验证和标准 `m.secret.request` / `m.secret.send` 请求 `m.megolm_backup.v1` 秘密。只接受同一 MXID、已验证、未封禁设备通过 Olm 加密返回且通过请求 ID、有效期、公钥和备份版本校验的响应。
8. Synapse 只保存加密的房间密钥备份、SSSS 密文和加密 to-device 事件。Business API不新增密钥传输或托管接口。
9. 没有可信旧设备且用户未导出恢复密钥时，业务账号和资金仍可恢复，但历史聊天不可恢复。
10. 消息展示区分“正在解密”“缺少密钥，无法解密”和非缺钥型“消息解密失败”；列表与聊天详情共享同一可观察恢复状态。
11. 数据库打不开、网络故障、Token 失效、账号封禁、备份异常或恢复失败均不得静默删除 Matrix 数据。
12. 所有诊断日志使用稳定错误码和脱敏标识，不记录消息正文、恢复密钥、Olm/Megolm 密钥、Token 或完整 Matrix 标识。

## 标准协议选择

采用 Matrix 已有的 SSSS、交叉签名、Olm to-device 加密、秘密请求和 room-key backup API，不使用 Business API自定义密钥信封。所谓“服务器中转密钥信封”是 Synapse 对 Olm 加密 `m.secret.send` 事件的暂存与转发，不代表服务器持有或能够解开恢复秘密。

## 安全理由

如果新设备在没有旧可信设备或用户秘密的情况下只凭服务器登录即可恢复密钥，服务器必然具有恢复能力，端到端加密边界随之失效。本决策选择同设备无感恢复、可信设备端到端传递和可选用户恢复密钥三条路径，同时接受“全部可信设备和恢复密钥均丢失时历史聊天不可恢复”的必要后果。

## 对既有 ADR 的影响

- 保留 ADR-0003 的双域持久会话、SQLCipher 和网络错误不清会话原则。
- 取代 ADR-0003 中“退出登录必须同时处理本地安全删除”的宽泛表述：普通退出不再删除 Matrix 数据；删除仅限本 ADR列出的两个显式条件。
- 扩展 ADR-0004：已恢复 Matrix 会话不申请登录令牌；只有同设备 soft logout/Token 失效时才申请，并指定原设备 ID完成非破坏性重新认证。
- 不改变 ADR-0005 对 Matrix server name、用户 ID和身份关键数据连续性的要求。

## 后果

- 普通退出后的本机仍保存由系统安全存储和 SQLCipher 保护的 Matrix 设备状态，APP 必须以 Business 认证门阻止未登录用户访问聊天。
- 同账号重登录不创建新 Matrix 设备，历史消息可继续使用本地会话解密。
- 在线备份和可信设备恢复增加异步状态、错误处理、设备验证 UI及真实 Synapse 集成测试。
- 明确清除本机数据在服务器离线时可能留下待用户以后从设备列表撤销的离线设备记录。
- 用户丢失全部可信设备且没有导出恢复密钥时，平台不能帮助解密历史消息。

## 回滚

实现必须以小步提交提供应用层回滚，但不得通过重新启用“Business 会话缺失即自动清库”回滚。若备份或可信设备恢复发布后出现故障，可暂时关闭新的自动恢复入口并保留本机数据库，继续允许用户重试或使用恢复密钥；不得删除现有在线备份、重置设备身份或把恢复密钥上传到服务器。

## 评审与生效条件

本 ADR 的产品行为已经批准，但属于受保护 E2EE/密钥恢复变更。以下两项书面评审均批准后，本 ADR 才能标记为“已批准”并进入发布：

1. Domain Review：身份绑定、同设备重新认证、Business/Matrix 权威边界、删除条件和无法恢复语义。
2. Quality/Security Review：SQLCipher、系统安全存储、设备信任校验、秘密不出端、日志脱敏、失败路径和端到端测试。

详细状态机、错误码、测试矩阵和发布验收见 `docs/superpowers/specs/2026-08-25-matrix-session-continuity-key-recovery-design.md`。
