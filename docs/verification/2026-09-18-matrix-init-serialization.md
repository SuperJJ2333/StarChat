# Matrix 客户端同库并发初始化串行化（提交 `04cc1d80`）

- 日期：2026-09-17（Asia/Hong_Kong）
- 背景：`android-ci.yml` 的 `Test (full suite)` 阶段出现**非确定性单例失败**：

```
synthetic credential write failure
constraint failed (code 1811)
Causing statement: INSERT OR REPLACE INTO box_client (k, v)
parameters: token, synthetic-second-token
```

## 1. 根因

`MatrixClientFactory.create()` **没有任何序列化**。同一进程里两次并发 `create()`
会各自走完「打开同一个 SQLite/SQLCipher 文件 → `Client.init()` → 写 `box_client`
token/credentials → 迁移」的完整序列，两个连接互相踩到对方的写入，于是表现为
`code 1811` 与 `INSERT OR REPLACE INTO box_client` 这类偶发失败。

已用实验确定：在 `test/features/matrix/matrix_client_factory_test.dart` 里注入
`opener`（覆盖「打开 + SDK 初始化 + 凭据写入」窗口）并发发起两次 `create()`，
**修复前最大重叠度 = 2**（8 路并发时为 8）。这证明缺陷在于**同一进程内的并发
初始化**，与跨进程共享目录是两件独立的事。

沿用的事实核对：

| 事实 | 证据 |
| --- | --- |
| 跨进程共享目录问题**已修** | `MatrixTestPaths` 现为 `Directory.systemTemp.createTempSync('chatflow-matrix-tests-$pid-')`，`git log -S` 显示该改动在 `81d9e612` |
| CI 失败发生在该修复**之后** | 用户引用的 `f869936a` 已含 `chatflow-matrix-tests-$pid-`，故 PID 隔离不足以解决 |
| 报错文案来自**触发器**而非 SDK | `sdk_invalid_token_store_retention_test.dart:113` 故意注册 `fail_token_write` 触发器（断言「写失败必须保留 store」）。该套件自身用 `createTemp('token-')` 隔离，单独跑 3 次全绿 |
| 生产只有单一创建入口 | `create()` 仅被 `main.dart:73` 调用；`_openPersistentClient` / `initializeClient` 都在其内部 |
| resume 路径同样经过该入口 | `main.dart` 里 `resumeClient: matrixFactory.create` |

## 2. 修复

`lib/features/matrix/matrix_client_factory.dart` 新增**按数据库路径**的初始化锁
`_DatabaseInitLocks`，并把 `create()` 的整段临界区包进去：

```dart
return _DatabaseInitLocks.run(databasePath, () async {
  if (await sessionStore.matrixClearPending()) {
    await _completePendingClear(databasePath);
  }
  final cipher = await sessionStore.matrixDatabaseKey();
  final client = await opener(
    clientName: clientName, databasePath: databasePath, cipher: cipher);
  try {
    await clientMigrator(client, homeserver);
    return client;
  } catch (_) {
    await disposer(client);
    rethrow;
  }
});
```

设计要点：

- **锁覆盖完整序列**：打开数据库 → SDK 初始化（含 `box_client` 凭据写入）→ 迁移 →
  返回 client。只锁路径生成不足以关闭窗口。
- **按路径加锁，而非一把全局锁**：不同数据库路径互不阻塞（对应「同一进程可能存在
  多个独立数据库路径」的场景）。
- **队列排空即移除条目**（仅当自己仍是队尾），避免 `Map` 无限增长；已用
  `MatrixClientFactory.debugPendingInitLockCount == 0` 断言。
- **失败路径不留悬挂**：`finally` 里必定 `complete()`，`create()` 内层异常仍按原逻辑
  `disposer(client)` 后 `rethrow`。
- **无生产调用点需要改动**：`create()` 是唯一入口，且 `resumeClient` 就是该函数。

## 3. 回归测试

`test/features/matrix/matrix_client_factory_test.dart` 新增分组
`同库并发初始化必须串行（CI box_client 写入竞态回归）`（**不触碰真实 SQLite**，
通过注入 `opener` 观测重叠）：

| 测试 | 断言 |
| --- | --- |
| 两次并发 `create` 不得重叠 | 两个 client 都返回；`maxConcurrent == 1` |
| 8 路并发全部串行、队列排空 | `completed == 8`；`maxConcurrent == 1`；`debugPendingInitLockCount == 0` |
| 串行 `create` 仍各自成功 | 锁不破坏正常路径 |

**TDD 证据**：新测试先红（`Expected: <1> Actual: <2>`）→ 加锁后转绿。

**变异探针**：把 `create()` 改回无锁版本 → 两条测试同时转红
（2 路 `Actual: <2>`、8 路 `Actual: <8>`）；复原后 3/3 绿。

## 4. 验证

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | **No issues found** |
| 并发回归组 | 3 通过（变异探针下 2 红） |
| `matrix_client_factory_test.dart` 全套 | 76 通过 |
| token/凭据/生命周期相邻套件 | 37 通过（无死锁、无超时） |
| `flutter test test/features/matrix` | **1630 通过** |
| 全量 `flutter test --timeout 120s` ×2 | **`+3173: All tests passed!`** ×2 |
| 格式 | `dart format` 干净 |

## 5. 为什么不用 `--concurrency=1`

它只是移除暴露问题的并行度，而不修复路径所有权：共享的初始化竞态仍在，一旦恢复并发
或测试分片方式改变就会复发，同时还会显著拉长 CI 墙钟时间。正确的修复是让**同一数据库
路径上的初始化串行**，本次即按此实施，未改动 CI 并发设置。

## 6. 未验证 / 剩余风险

- **本地未能复现原 CI 失败**：当前 HEAD 上全量套件连跑 5 次（含 3 次修改前）均为
  `All tests passed`，故本次修复的正确性由**确定性重叠实验 + 变异探针**支撑，
  而非「让一个本地可复现的失败转绿」。CI 环境并发度更高，仍需下一次 CI 运行确认。
- **触发器机制的解释**：`synthetic credential write failure` 文案来自
  `sdk_invalid_token_store_retention_test` 故意注册的触发器。该套件自身已隔离目录；
  本次串行化关闭的是**同一进程内并发初始化**这一窗口。若 CI 仍出现同文案失败，
  需按「是否有第三方进程/路径指向同一数据库文件」继续追查，而不是继续加锁。
- 全量日志中仍会打印该文案（来自故意触发失败路径的断言），**不属于失败**；
  判定标准应看 `All tests passed` / 失败测试清单，而不是日志里出现该字符串。
