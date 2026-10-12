# Android 0.4.46+2215 最终共享门禁

## 恢复入口

- 最终产品候选：`e432414276af7d6fe73afd9afc8b41d7bfd4b5b7`，其相对 `ec9a38a882096d80ff4a6ed1e31078dae95ee641` 唯一变化为 iOS unsigned CI 六处版本/文件名 literal 对齐；未触发 iOS workflow、构建或发布 iOS。
- 目标与授权：root 委派最终移动共享全量、分析、Python/mobile 边界和 verify 环境预检；用户已授权修复 Android 图片/视频红叹号。本子任务只新增本证据目录，不修改产品、原测试、锁文件或服务；不访问 ADB/设备、不构建 APK。
- 工作树：`C:/Users/Administrator/.codex/worktrees/media-send-startup-2214/StarChat`；分支 `codex/media-2215-final-gates`。阶段：此范围验证完成，设备与发布仍由 root 负责。
- 关联：现有 IM 可靠性 R8 媒体修复；最小修复与 RED/GREEN 见兄弟目录 `media-send-startup`，这里是实际 2215 最终候选的新门禁，不复用历史 5958 项来冒称新源码通过。

## 实际结果

| ID | 门禁 | 实际结果 | 最终候选绑定 |
| --- | --- | --- | --- |
| G1 | `flutter test --no-pub --reporter expanded` | exit 0；5965 PASS / 9 SKIP / 0 FAIL | ec9 上新执行，2102 mobile 文件+generated inputs+native DLL 完整闭包与 e432 相同，精确复用 |
| G2 | `flutter analyze --no-pub` | exit 0；No issues found | 同一完整移动输入闭包精确复用 |
| G3 | 原 `py -3.12 -m pytest -q -p no:cacheprovider tests/mobile tests/test_android_delta.py` | e432 上自然 exit 0；401 PASS / 1 SKIP / 0 FAIL | CI 契约输入变化，重新完整执行；672 输入前后零漂移 |
| G4 | Repository policy | e432 上新执行 exit 0 | `boundaries/repository-policy-final-*` |
| G5 | Deployment policy / Template tools | 实际 verify 前缀 PASS | 对 e432 的未变依赖闭包复用，不伪造整脚本 exit 0 |
| G6 | UI drift | 实际 exit 0；34 components / 535 screens | 未变 UI/验证器依赖闭包复用 |
| G7 | `pwsh.exe -NoProfile -File scripts/verify.ps1` | 实际 exit 1；本地缺 `.env`，停于 render-only init_matrix.ps1:19 | 环境阻断原样保留；未创建/导入配置或生产秘密 |

这些结果确认共享客户端测试与静态边界；不是 Android/iOS 原生编译、真实设备 SQLCipher、实际编码、服务器 ACK 或媒体到达验收。9 个 Flutter skip、1 个 Python skip 均计入报告；本次 expanded/-q 记录不逐项解释原因，不推断未打印的 skip 原因。

## 输入与复用依据

原依赖锁 SHA256：`a43833c8e7c3d6faa93d21babdc61dfe4b3563c7ac00912006f26daa8e0ecc5d`。显式 `PUB_HOSTED_URL=https://pub.dev` 执行 `flutter pub get --offline --enforce-lockfile` exit 0；比较实际 package_config 的216个 hosted versions，0 mismatch。Flutter3.44.9、Dart3.12.2、Python3.12.10、Windows19045；工具与本机 native DLL SHA 见 environment/receipts。

- ec9 完整 manifest：`mobile-input-manifest.json`，2102文件，SHA `bf8524c0da20b4a1700fb43c07bd3a5344c08e9c2f2a5e33a3bbf1f8cdee9050`。
- e432 完整 manifest：`final-mobile-input-manifest.json`，2102文件，SHA `f08ce77be8b503f691beebb605f5423ef883146a76f3a341df8001cfe00e2ae1`。
- `ci-mobile-gate-reuse.json`：自动核对两个完整列表与每个SHA、generated inputs、原 native runtime；Git commit diff 严格只有 CI workflow。G1/G2 原始前后输入一致，日志/receipt hash 也纳入复用证明。
- `boundaries/final-gate-reuse.json`：部署、模板、UI与缺.env阻断的逐项依赖范围；Python因契约文件改变实际重跑，未把旧失败当通过。
- 复用只免除不变移动输入的重复8分钟运行，未抹除原始命令候选身份。候选 e432 对应不同 source_commit 的 manifest 单独保存。

Flutter使用既有只读 libolm/SQLCipher Windows runtime；未伪造 DLL/变更加密实现。全量采用本任务独占 V: 映射，已核对所有权并清理，未占用 root 的 W:。既有测试只在本工作树 ignored verification 路径产生合成 fixture；这些数据库/媒体不纳入 Git。

## 失败保留与修复闭环

ec9 首轮 Python 全量真实 exit 1：396 PASS / 5 FAIL / 1 SKIP。四项 android_delta 因其硬编码历史临时父目录不存在，在 setup WinError3；显式创建本树原测试所需 ignored parent 后，原四项命令4/4通过，没有改断言、monkeypatch或换实现。另一项是 iOS CI literal2214与共享pubspec2215不一致，root 在 e432 修正六处 metadata，本次 e432 原始全量401/1通过关闭该失败。首轮日志、receipt、原报告及 delta 补验全部保留在 boundaries 目录。

`.env` 仍不存在，verify 全仓后续 infra/Getui/Bot/Business API/Worker/AST/Alembic/OpenAPI 等阶段未执行；本媒体客户端任务不扩展无关业务全量，也不声称全仓 verify 已通过。此环境限制不等同新的客户端测试失败。

## 阶段计时与交接

各命令精确起止采用 UTC receipt，不以文件时间猜工时。pinned pub get：12:39:42–12:40:02；Flutter gate：12:41:12–12:49:22（8分09秒墙钟，测试报告7分40秒）；Analyze并行：12:41:12–12:41:44；e432 Python全量：12:53:44–12:54:21（37.16秒墙钟）。并行区间不能相加；root metadata修正等待和本地归档时间独立记录，未精确采样主动工时。

下一步由 root 把本门禁与同源debug/正式重建包SHA绑定，在模拟器实际保留数据安装，复核房间图片、视频真实上传/ACK/重开房间可见，再按批准发布流程进行最终包与分发验收。此处没有安装、发布或生产回退操作；没有运行中的子任务/Flutter进程或本任务映射。正式 iOS 发布状态由 root 管理，不能从本桌面门禁推断。
