# ADR-0072：Matrix device id 轮换不属于身份变化，连续性锚点重新界定

日期：2026-09-16。状态：**提案，待用户批准**（用户在本轮明确要求修复 iOS build 2121 仍存在的 L04/L07，并同时要求"不允许弱化 E2EE continuity 校验"、"不要把可恢复的 server device rotation 误判成身份损坏"、"不要让真正的 cryptographic identity mismatch 被自动修复"）。本 ADR 记录代码已经实施的语义决策，领域与质量/安全审查尚未由用户指定的审查人签署。

## 背景

ChatFlow 用 `MatrixLocalBinding` 记录"本机保存的加密库属于哪个 Matrix 身份"。iPhone 覆盖安装、杀进程重启后，Keychain 里的 binding 与沙盒里的 SQLCipher 库必须仍然互相匹配，否则不允许继续使用本地历史与 E2EE 会话。

原实现把 `deviceId` 与 `matrixUserId`、`homeserver`、`databaseGeneration`、`ed25519Fingerprint` 并列当作身份锚点：任何一项不同即视为"恢复出了另一个身份"并失败关闭。

但 `deviceId` 与服务端行为耦合：服务端单设备登录策略会在另一端登录时吊销本机旧设备，并在本机重新登录时把 `device-OLD` 轮换成 `device-NEW`。SDK 的 `Client.init(newDeviceID:)` 会把新 device 写进本地库（`updateClient`），而 ChatFlow 自己维护的 binding 不会自动跟着走。结果是：

```
client.deviceID = device-NEW     (本地库已更新)
binding.deviceId = device-OLD    (Keychain 未更新)
→ continuityMetadata 抛 "Matrix client does not match the local binding"
→ 登录在 matrix_login 阶段失败 → 用户看到 L04
→ 失败清理里 suspend 再次读取 continuity 又失败 → 半挂起
→ 之后每次 selectAccount 都失败 → 用户看到 L07（account_storage）
```

这是把"服务端随时可以轮换的设备标签"误判成了"本地密码学身份改变"。

## 决策

1. **连续性锚点只包括**：`matrixUserId`、`homeserver`、`ed25519Fingerprint`（Olm 身份）、`databaseGeneration`（本地库代号）。其中 `ed25519Fingerprint` 与 `databaseGeneration` 是真正的密码学/存储锚点。
2. **`deviceId` 不再是身份锚点**。`MatrixClientContinuityMetadata.hasSameContinuity` 不再比较它；同账号、同 homeserver、同 Olm 身份、同库代号的两次观察被视为同一身份，即使服务端 device 标签不同。
3. **轮换必须被服务端证明**。`loginWithToken` 的保留身份路径中，只有 `m.login.token` 登录成功、服务端返回的 `user_id` 等于本机保留身份、且返回非空 `device_id` 时，才允许迁移 binding。迁移入口 `MatrixClientFactory.rotateDeviceBinding` 与存储层 `SecureSessionStore.rotateMatrixDeviceBinding` 独立复核：client 最终 `userID/deviceID` 与请求一致、binding 的 `matrixUserId`/`homeserver`/`ed25519Fingerprint` 与现网事实逐字相同、新 device 非空且与旧值不同。任何一项不成立即抛 `MatrixDeviceBindingRotationRejected` 并保留原 binding（失败关闭）。
4. **只改 `deviceId`**。迁移后的 binding 保持 `matrixUserId`、`homeserver`、`databaseGeneration`、`ed25519Fingerprint` 不变；整个过程在 `SecureSessionStore` 的 identity 串行区内一次写入完成，与其它 scope/binding 操作原子互斥。
5. **为旧版本遗留态提供一次自愈**。build 2121 已经可能把 `device-NEW` 写进本地库而 binding 仍是 `device-OLD`（进程在写 binding 前被杀）。这种状态若不修复，用户升级后永远无法登录。因此 `continuityMetadata` 在读到"只差 device id"时，用 `SecureSessionStore.adoptMatrixDeviceId` 补齐，并记录 `E2EE_DEVICE_ROTATION_DETECTED` / `E2EE_DEVICE_ROTATION_BINDING_MIGRATED`。该路径**不接受**账号、homeserver 或 fingerprint 的任何差异。
6. **关闭安全与连续性信任分离**。`suspend()` 一旦开始，只有底层 client 自身 dispose 失败才允许中断；continuity 读取失败只记录日志并把状态显式标为 `MatrixSuspendedContinuity.unknown`，绝不假装已验证。continuity 判定为 unknown 时 `_suspendedMetadata` 为 null，后续 resume 仍失败关闭。

## 后果

- 单设备登录、账号切换、iOS 持久化、失败恢复成为一致、原子、可重试的生命周期。
- 真正的身份错配（换账号、换 homeserver、Olm 身份变化、库代号变化）仍然失败关闭，且各自有独立事件码便于定位。
- 唯一的放宽点是 `deviceId` 不再参与身份比较。风险评估：能改写本地库的攻击者必然已持有 Keychain 中的库密钥，而能改写 Keychain 的攻击者可直接改写 binding，因此该放宽不提供新的攻击能力；`deviceId` 也从来不是密码学材料。
- 遗留态自愈意味着"库已轮换、binding 未轮换"不再需要清库或重建身份即可恢复，符合"不允许通过清库规避问题"的约束。
- 用户可见的 `L04/L07` 阶段码与文案保持不变，只增加本地诊断事件码与加盐哈希标识字段。
