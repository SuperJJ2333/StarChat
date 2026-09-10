# iOS 卸载重装后可恢复的登录失败（L07）修复设计

日期：2026-09-11（Asia/Hong_Kong）。分支：`codex/ios-reinstall-l07`，基线 `8ec6782e`。
关联：ADR-0062（移动端单设备会话）、ADR-0063（切换账号保留本地聊天存储）、本设计配套 ADR-0068。

## 1. 现象与最短复现

用户报告（iPhone 8，企业版）：

> 删除卸载 APP 后，再安装 APP 登录相同的账号，然后出现原本账号被弹出的提示，就会显示"聊天登录未完成，请重试（L07）"。

补充信息（用户确认）：两个提示都出现在**同一台 iPhone 8** 上；**全程未进入主界面**；顺序是**先弹被登出，再报 L07**。

最短复现：iOS 设备上卸载应用 → 重装 → 用卸载前的同一账号登录。Android 上同样操作不出现。

受影响版本：包含 `e373329b`（保留式单设备登录）及以后的全部客户端，即当前 iOS 企业版 0.3.81/2085。
服务端无需改动。

## 2. 根因

### 2.1 平台差异是根因的入口

卸载应用时两端清理范围不同：

| | 沙盒文件（SQLCipher 库、SharedPreferences、账号聊天存储） | 系统钥匙串（业务会话、账号注册表、当前槽指针、数据库密钥、绑定、注册设备键、恢复密钥、诊断盐） |
| --- | --- | --- |
| Android | 随应用数据删除 | `flutter_secure_storage` 落在应用数据内 → 一并删除 |
| iOS | 随应用容器删除 | **iOS 钥匙串项不随卸载删除** → 全部保留 |

`SecureSessionStore` 的绝大多数条目在 iOS 上都是钥匙串项：四个固定 key 走原生桥
`chatflow/ios_secure_session`（`session_store.dart:22-32`），其余走 `flutter_secure_storage`，
在 iOS 上同样是 `kSecClassGenericPassword`。因此 iOS 卸载后形成的状态是
**"钥匙串完整保留 + 沙盒（含加密库文件）清空"**，而 Android 是干净状态。

### 2.2 L07 的触发链

L07 是 `LoginStageException` 中 `account_storage` 阶段的诊断码（`login_controller.dart:367`）。

1. 重装后登录成功，`business.currentMatrixUserId()` 返回该账号的 MXID（该函数是**纯本地读**：
   `business_api_client.dart:641-643`，值来自登录响应写入的 `business_session.v1`），
   于是 `_loginRetained()` 判定 `matrix.userId != target`，置
   `_stage = 'account_storage'` 并调用 `selectAccount()`
   （`login_controller.dart:254-258`）。
2. `MatrixSdkE2eeClient._selectAccount` 依次执行 `select()`、`resume()`、
   `_readContinuityMetadata()`（`matrix_e2ee_client.dart:2725-2771`）。
3. `MatrixClientFactory.continuityMetadata` 读到**仍然存在的本地绑定**
   （`matrix_local_binding.v1.<slot>`，钥匙串保留），但重新打开的加密库
   **没有任何身份**（数据库文件已随沙盒删除，`userID` / `deviceID` 均为 null）。
   守卫因此落到第二个分支（`matrix_client_factory.dart:99-119`）：

   ```dart
   if (!client.isLogged() && client.userID == null &&
       client.deviceID == null && binding == null) {
     return <无连续性元数据>;                       // Android 走这里
   }
   ...
   if (userId == null || deviceId == null || ...) {
     throw StateError('Matrix continuity identity is unavailable');  // iOS 走这里
   }
   ```

4. 该异常冒泡到 `_loginRetained` 的捕获处，`_stage` 仍是 `account_storage`
   → `LoginStageException('account_storage')` → 界面显示"聊天登录未完成，请重试（L07）"。

**已经代码级复现**：`test/features/matrix/ios_reinstall_continuity_test.dart`（本任务新增）
构造"钥匙串存活 + 加密库为空"，断言抛出的正是
`StateError('Matrix continuity identity is unavailable')`，并断言无绑定残留时（Android 情形）
不抛。

### 2.3 "被登出"提示的来源与归因

该文案来自 `session_bootstrap_controller.dart:82-84`，由业务 API 返回 401
`SESSION_REPLACED` 触发。服务端在任意一次登录时会撤销该用户**全部**未撤销的
refresh token family（仅管理后台 family 豁免；`tokens.py:56-66`），因此"被登出"是
单设备策略的预期结果。

**已排除的假设**：不存在"同一 deviceKey 登录会撤销本次刚创建的新会话"的路径——
撤销 SELECT 在语句顺序上先于新 family 的创建，且在同一个事务内
（`tokens.py:56-66` 先撤销，`:85-92` 后创建）。

**未实测确认的归因**：重装后首次启动时，随钥匙串存活的**旧业务会话**被
`restoreSession()` 恢复，而该 family 可能已因他处登录成为 `SESSION_REPLACED`，
从而先弹出被登出提示。此归因与代码逻辑一致，但**没有设备实测证据**，按风险记录而非结论。

### 2.4 缺陷的准确表述

真正的缺陷不是某个守卫写错了，而是**应用无法区分"同一安装的延续"与"全新安装但钥匙串有残留"**。
现有守卫在"库为空而绑定仍在"时只能按最坏情况处理，于是把一次正常的重装登录判成了完整性损坏。
同源的残留还会影响：注册设备键（永久复用卸载前的设备身份）、旧业务会话（如上）、
账号注册表与当前槽指针（指向已不存在的库）。

## 3. 设计

### 3.1 概念：安装世代（installation generation）

在**随卸载一起消失**的存储中保存一个安装标记。启动时读取：

- 标记存在 → 同一安装的延续，不做任何清理。
- 标记缺失 → **尚不能断言是全新安装**，需要第 3.2 节的证据判断。

`SharedPreferences` 在 iOS 落 NSUserDefaults（应用容器内）、在 Android 落应用数据，
两端都随卸载消失，正是所需语义。Android 重装后标记同样缺失，但没有任何遗留可清，
清除为空操作，因此两端行为一致——这正是本设计的意图：**让 iOS 重装后的本地状态
收敛到与 Android 卸载后相同的干净状态**。

#### 3.1.1 标记缺失不等于全新安装

标记由本变更引入，因此**存量安装升级到含本修复的版本时，标记必然缺失而容器完好**。
若把"标记缺失"直接等同于"全新安装"，覆盖升级会走清除分支，删掉**正在使用**的
数据库密钥，而加密库文件留在磁盘上：后果是本地聊天记录永久不可解密、用户被强制
登出，且对 ADR-0063 之前的空槽布局，`create()` 会拿新密钥重开同一个
`liuhetong_matrix.sqlite`，异常在 `matrixFactory.create()` 抛出——位置在 `runApp`
之前且无捕获，启动即失败。这是设计缺陷，不是实现缺陷。

### 3.2 证据判断：容器产物

容器随卸载消失、钥匙串不会。因此"上一次安装是否在容器里留下了产物"是可靠判据。

判据取**应用支持目录中是否仍存在 Matrix 加密库文件**（名称形如
`liuhetong_matrix*.sqlite`，含迁移期的 `.sqlite.encrypted`）：

| 标记 | 库文件 | 判定 | 动作 |
| --- | --- | --- | --- |
| 存在 | — | 同一安装的延续 | 不做任何事 |
| 缺失 | 存在 | 覆盖升级的延续 | **只写入标记，不删除任何密钥** |
| 缺失 | 不存在 | 全新安装 | 清除全部遗留 → 写入标记 |

选这个单一信号而不是"偏好存储非空"之类的组合信号，原因是**假阳性方向不同**：

- 库文件在重装后不可能残留——卸载会删除整个容器。故它对"全新安装"**没有假阳性**，
  而假阳性会使该清除的遗留被跳过、L07 复发。
- 反过来，只要应用成功启动过一次，`MatrixClientFactory.create()` 就会建立该文件，
  因此覆盖升级几乎不可能漏判。
- 偏好存储等其他容器产物可能因渠道或迁移原因残留，把它 OR 进来只会引入上面那种假阳性。

探测失败（目录不可读等）按"不确定"处理：既不删除也不写标记，下次启动重试——
与标记读取失败同一条保守规则。

### 3.3 部件

| 部件 | 位置 | 职责 |
| --- | --- | --- |
| `InstallationMarkerStore`（抽象）+ `SharedPreferencesInstallationMarker` | `lib/core/installation_marker.dart`（新） | 读写安装标记；仿现有 `ThemePreferenceStore` 模式，便于注入测试替身 |
| `InstallationContainerProbe`（抽象）+ `FileSystemInstallationContainerProbe` | `lib/core/installation_container_probe.dart`（新） | 回答"上一次安装是否在容器里留下了 Matrix 加密库"，即 §3.2 的证据判断 |
| `SecureSessionStore.clearInstallation()` | `lib/core/session_store.dart` | 一次性清除全部钥匙串遗留 |
| `InstallationReconciler` | `lib/core/installation_reconciler.dart`（新） | 编排：读标记 → 按需探测 → 按需清除 → 写标记 |
| 启动装配 | `lib/main.dart` | 在构造 `BusinessApiClient` / `MatrixClientFactory` 之前、`matrixFactory.create()` 之前调用 |

抽象接口（与既有 `ThemePreferenceStore` 风格一致）：

```dart
abstract interface class InstallationMarkerStore {
  Future<bool> isRegistered();
  Future<void> register();
}

abstract interface class InstallationContainerProbe {
  Future<bool> hasPreviousMatrixStore();
}
```

`FileSystemInstallationContainerProbe` 使用与 `MatrixClientFactory` 相同的支持目录
（`getApplicationSupportDirectory()`），按 `liuhetong_matrix*.sqlite` 及
`.sqlite.encrypted` 匹配文件名。目录读取失败时抛出，由协调器按"不确定"处理。

### 3.4 清除范围

`clearInstallation()` 作用于 `_AccountScopedSecureStore.raw`，**绕过作用域间接层**
（它要删除的正是作用域本身），删除集合：

- 对候选后缀集合中的每个后缀 `s`，删除
  `matrix_database_key.v1[.s]`、`matrix_local_binding.v1[.s]`、
  `encrypted_recovery_key[.s]`、`diagnostic_salt.v1[.s]`、
  `matrix_clear_tombstone.v1[.s]`；
- `active_matrix_scope.v1`、`matrix_account_slots.v1`；
- `business_session.v1`、`registration_device_key.v1`；
- 遗留键 `access_token`、`refresh_token`。

候选后缀集合 = `{空后缀} ∪ 注册表中出现的全部槽值`。空后缀用于覆盖
ADR-0063 之前的单账号遗留（其键无后缀）。
**注册表不可解析时不得阻断清除**：改为从原始注册表字符串中提取全部
`[a-f0-9]{64}` 串作为候选后缀。清除动作只依赖"已确定是全新安装"，
不依赖注册表完整性。

### 3.5 顺序与失败模式

启动顺序（强制）：`WidgetsFlutterBinding.ensureInitialized()` →
创建 `SecureSessionStore` → **`InstallationReconciler.reconcile()`** →
`BusinessApiClient` / `MatrixClientFactory` → `matrixFactory.create()`。
任何读取钥匙串遗留的动作都必须发生在 `reconcile()` 之后。

四条失败规则，必须分别守住：

1. **标记读取失败 → 既不清除也不写标记。** 在不确定的情况下绝不抹掉有效会话，
   本次启动按"延续"处理，下次启动重试。这是保守方向。
2. **容器探测失败 → 同样既不清除也不写标记。** 探测回答的是"密钥是否还有效"，
   探测不出来就不能删任何东西。与规则 1 同一方向。
3. **判定为覆盖升级的延续 → 只写标记，绝不删除任何密钥。** 这是 §3.1.1/§3.2
   存在的全部理由；漏掉这一步会造成存量安装升级后数据永久不可解密。
4. **清除失败 → 不写标记。** 否则残留被永久化，下次启动不会再重试。
   清除按逐键尽力执行，记录首个错误并在结束时抛出，由调用方决定是否降级启动。

**注册表损坏不在此列**：它只在"已判定为全新安装"之后影响候选后缀的枚举方式，
因此不得阻断清除（见 §3.4）。

`reconcile()` 的返回需要让调用方区分四种落点：延续无需动作、延续并已播种标记、
全新安装已清理、状态未落定。注意"未落定"覆盖读取/探测/清除/播种四步中任一步失败，
其中只有清除失败意味着遗留仍在——调用方不应把该值一律理解为"没清掉"。

### 3.6 与 ADR-0063 的关系

ADR-0063 第13条要求"清库只删除当前槽及其密钥，不影响其他账号"——那约束的是
**同一安装内的账号切换**。本设计处理的是**全新安装**：此时每个槽的加密库文件
都已随沙盒消失，没有任何一个槽还有可读数据，因此删除全部槽不违反该约束。
本设计不修改账号切换路径上的任何行为。

### 3.7 明确不做

- 不修改 `continuityMetadata` 的完整性守卫（它在"同一安装内库被意外清空"时仍然应当失败关闭）。
- 不修改 `selectMatrixAccount` 的注册表冲突判定。
- 不做 E2EE 算法、密钥恢复流程或服务端契约的任何变更。
- 不尝试跨重装保留 E2EE 设备身份：Olm/Megolm 状态随加密库一起消失，无法保留；
  服务端单设备策略本就会删除其他设备。

## 4. 测试

| ID | 场景 | 预期 |
| --- | --- | --- |
| T1 | 钥匙串有绑定与库密钥、容器无库文件（iOS 重装态） | 修复前抛 `Matrix continuity identity is unavailable`；`reconcile()` 后不再抛，`continuityMetadata` 返回无连续性 |
| T2 | 无绑定的空库（Android 重装态） | 始终不抛；`reconcile()` 走全新安装分支，清除无可删对象，标记写入 |
| T3 | 标记已存在 | 探测与清除都不被调用，钥匙串内容逐键不变 |
| T4 | 清除覆盖多槽 | 两个槽的全部作用域键、注册表、当前槽指针均不存在 |
| T5 | 注册表损坏 | 清除仍完成；不因解析失败中断 |
| T6 | 某个键删除失败 | 标记**未**写入；解除故障后再次 `reconcile()` 重试，最终 `cleared` 且标记写入一次 |
| T7 | 标记读取抛错 | 清除与探测都不发生、不写标记，且不误删任何键 |
| T8 | 空后缀遗留（ADR-0063 之前的单账号数据） | 无后缀键一并清除 |
| **T9** | **标记缺失 + 容器仍有 Matrix 库文件（覆盖升级）** | **判定为延续：`adopted`，逐键断言清除未发生、标记写入；`continuityMetadata` 行为与修复前一致** |
| **T10** | 标记缺失 + 容器无库文件 | 判定为全新安装：`cleared`，遗留清除，标记写入 |
| **T11** | 容器探测抛错 | `failed`；不清除、不写标记、逐键断言键集不变 |
| **T12** | `FileSystemInstallationContainerProbe` 的文件识别 | 支持目录含 `liuhetong_matrix.sqlite`、`liuhetong_matrix_<64hex>.sqlite`、`.sqlite.encrypted` 时返回真；目录不存在或只有无关文件时返回假 |

T9 是 §3.1.1 的直接回归防线：**没有它，覆盖升级会把存量安装的数据密钥删掉而测试全绿**。
T1–T2 已作为复现用例存在（断言修复前行为），实施时按 TDD 反转断言。
回归范围：`session_store_test`、`matrix_client_factory_test`、`account_client_selection_test`、
`session_bootstrap_controller_test`、`ios_secure_session_test`，以及共享逻辑改动后的
`flutter analyze` 与最终候选的 Flutter 全量门禁。

## 5. 验收

| ID | 要求 | 验证方式 |
| --- | --- | --- |
| A01 | 重装后同账号登录不再出现 L07 | 单测 T1 由红转绿 |
| A02 | iOS 重装后的本地状态与 Android 卸载后一致 | T3–T5、T8 全绿；逐键断言 |
| A03 | 清理失败不会静默永久化残留 | T6 断言标记未写入，且重试后写入 |
| A04 | 不因标记读取失败而误删有效会话 | T7 |
| A05 | 现有完整性守卫与账号切换行为不变 | 相关回归套件全绿 |
| **A07** | **覆盖升级不丢失任何有效密钥，启动不因密钥错配失败** | **T9、T11、T12 全绿；T9 必须逐键断言"一个键都没被删"** |
| A06 | 真机确认 | **未完成**，需 iPhone 8 安装含本修复的构建后复测；本设计不声称已通过 |

## 6. 未决与风险

- **A06 是唯一能确认根因的最终证据**，目前只有代码级复现。§2.3 的"被登出"归因同样待实测。
- **A07 的现场形态仍是推断**：覆盖升级的后果（数据不可解密 vs 启动失败）按代码推演，
  未在真机上复现。判据本身（容器库文件是否存在）不依赖这个推断，它对两种形态都成立。
- 判据依赖库文件名保持 `liuhetong_matrix*.sqlite`。若将来重命名，探测会退化为
  "永远看不到产物"，从而把覆盖升级误判为全新安装。`MatrixClientFactory.databaseFileName`
  与探测的正则必须一起改；T12 与工厂测试共同约束这一点。
- **已接受的限制：首次启动核对失败会永久固化"延续"判定。** 若全新安装的第一次启动里
  `reconcile()` 失败（标记读取或探测抛错），按规则不写标记；但同一次启动稍后的
  `matrixFactory.create()` 会创建加密库文件。于是第二次启动看到的是"标记缺失 +
  库文件存在"，判为覆盖升级，残留不再被清除——L07 会保留到用户下次重装为止。
  没有采纳的替代方案：在核对失败时写标记会永久化残留；在拿不到判断依据时清除会
  重新引入 §3.1.1 的数据损失。两者都比"修复不生效"更糟，因此保留保守方向，
  并把它记为已知限制。触发前提是启动早期两次独立的存储读取都失败，概率低。
- 诊断可见性：主工作树中已存在另一任务的 `[L07Debug]` 调试插桩（未提交），其打印被
  `kDebugMode` / `assert` 包裹，**在企业版 release 包中不会输出**。若需要在真机上直接取证，
  应在该任务内决定是否改为受限的 release 可见诊断；本设计不擅自修改那些文件。
- 本变更会删除密钥材料，属于存储安全边界变更：按 AGENTS.md 受保护变更处理，
  需 ADR-0068 及领域与 Quality/Security 双评审。
