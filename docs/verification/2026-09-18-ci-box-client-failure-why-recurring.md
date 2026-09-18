# CI box_client 写入失败：为何反复出现，以及本轮改了什么（提交 `bd28dbff`）

- 日期：2026-09-18（Asia/Hong_Kong）
- 触发：`android-ci.yml` `Test (full suite)` 报 `3172 passed, 1 failed`，
  日志含 `SqliteException(1811): synthetic credential write failure` +
  `INSERT OR REPLACE INTO box_client (k, v) VALUES (?, ?)`（参数 `token, synthetic-second-token`）。

## 1. 为什么同一问题反复出现（诚实复盘）

前两轮修复都没有解决它，原因**不在于修复本身，而在于我的诊断方式**：

| # | 我的做法 | 为什么不能收敛 |
| --- | --- | --- |
| 1 | 从**报错文本**反推机制（先推「跨进程共享目录」→ 做 PID 隔离；再推「同进程并发 create」→ 做按路径锁），然后等下一次 CI 验证 | 每次只验证一个假说，且**从未确认失败的具体测试名**。直到本轮才发现：该文本来自一个**故意**注册触发器的测试，它同样出现在**通过**的运行里——也就是说我一直在拿噪音当根因 |
| 2 | 从未读到 CI 结论本身 | 仓库为私有，`api.github.com` 从本机未鉴权返回 403，只能依赖片段转述；于是「修一轮→等 CI→再修」成为唯一节奏 |
| 3 | 本轮我还自造过一个假阳性 | 我在并发压测命令里传了不存在的 `account_chat_store_test.dart`（真实文件在 `test/core/` 下），得到 `+95 -1` 便以为复现，实际是文件不存在导致的加载失败 |
| 4 | 本轮还写过一个**检测不到目标缺陷**的测试 | 「真实磁盘并发 create」测试在**移除锁**后照样通过（变异探针），说明它覆盖不到锁；保留它只会制造「已覆盖」的错觉。已删除并把该结论写进测试文件注释 |

结论：**反复出现的根因是「用噪音当证据 + 无法看到失败测试名」**，而不是同一段代码反复坏掉。

## 2. 本轮取得的确定性证据

| 证据 | 方法 | 结果 |
| --- | --- | --- |
| 并发放大**不是**诱因 | 7 个会碰真实 SQLite 的套件同时并发跑，3 轮 | 每轮 **110 全部通过** |
| 上一轮的锁**不能**阻止该失败 | `git merge-base --is-ancestor 04cc1d80 3c61dc27` | 退出码 0（锁修复已是失败提交的祖先） |
| 正常 SQLite 路径**不**产生 1811 | 变异探针：移除 `_DatabaseInitLocks` 后跑真实磁盘并发测试 | 仍然通过 |
| 该文本只可能来自那个故意测试 | 全测试目录搜索 `synthetic-second-token` | 仅 `sdk_invalid_token_store_retention_test.dart:120`，其触发器在该库上 `INSERT INTO box_client` 时 `RAISE(ABORT,'synthetic credential write failure')` |
| 其余真实库套件均已隔离 | 逐个检查路径来源 | `account_history_disk` / `sdk_recall_persistence` / `sdk_receive_burst_benchmark` 都用 `createTemp(...)` 子目录；`device_rotation_login_lifecycle` 用固定路径但注入 fake sandbox（不碰真实 SQLite） |

即：**我前两轮修的方向（并发/隔离）都不是这次失败的原因**；这次失败最可能来自那个故意制造失败的测试自身。

## 3. 本轮改动

### 3.1 CI：把「哪个测试失败」变成一等证据（`android-ci.yml`）

- 仍然原样运行 `flutter test`（**未**改并发、未跳过任何测试）；
- 完整日志落盘并在失败时上传为 artifact `flutter-test-log`；
- 失败时从日志提取 `Failing tests:` 段落，写成 **job annotation** 与 **step summary**，
  下次失败**不必下载 artifact 也能直接看到失败测试名**；
- 管道状态在任何 `fi` / `{}` 覆盖 `$?` **之前**捕获（`set +e` → 取 `status` → `set -e`）。

### 3.2 测试：消除信噪比、彻底隔离（`sdk_invalid_token_store_retention_test.dart`）

- 数据库移到**进程唯一**的系统临时目录
  （`chatflow-token-retention-$pid-`，不再落进仓库 `docs/verification/artifacts/**`）；
- 每个用例打印 `[token-retention-probe] preserve=… softLogout=… db=… pid=…`，
  让「故意的失败」与「真实失败」在日志里可区分。

### 3.3 测试：删除无效覆盖（`matrix_client_factory_test.dart`）

- 移除「真实磁盘并发 create」测试（变异探针证明它检测不到锁），
  并在原位留下注释记录该结论，避免后人重复投入。

## 4. 验证

| 项目 | 结果 |
| --- | --- |
| 工作流静态检查 | 9/9 通过（含 `set +e`/`status` 顺序、注解、summary、artifact） |
| 工作流行为实测（stub `flutter`） | 失败路径 `exit 1` + 注解 + summary 命中；成功路径 `exit 0` |
| 全部 workflow YAML | 可解析 |
| `flutter analyze` | No issues found |
| `sdk_invalid_token_store_retention_test` | 5 通过，probe 日志带 `pid` 且路径在系统临时目录 |
| 全量 `flutter test --timeout 120s` ×2 | **`+3173: All tests passed!`** ×2 |
| 推送 | `bd28dbff`；`origin/main...main` = `0 0`；工作流改动已确认在 `origin/main` |

## 5. 仍未确定的部分（不掩饰）

- **我依然不知道 CI 上失败的到底是哪一个测试**。本轮没有再靠猜去改代码，而是把「拿到失败测试名」这件事做成了自动输出。下一次 CI 失败会直接给出测试名（annotation + summary + artifact）。
- 若下一轮 CI 显示失败的确实是 `sdk_invalid_token_store_retention_test` 的某个用例，
  下一步应查该用例在 Linux/CI 上为何不满足其断言（例如 `ClientInitException` 未抛出、
  或某个 `await` 顺序差异），而不是继续在并发/隔离上投入。
- 若下一轮 CI 显示失败在别处，则说明该文本只是噪音，真实缺陷另有其因——届时以 CI 给出的测试名与堆栈为准。
- 本轮**没有**用 `--concurrency=1`（那只是隐藏并行度，不修复任何东西），也**没有**放宽任何断言。
