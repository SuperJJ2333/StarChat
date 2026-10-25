# Android 2235 安装包交付

## 恢复入口

- 授权：2026-10-25用户要求更新Android安装包，暂不推送更新提醒；已回复“交付APK，并更新官网下载入口”。允许该范围上传/下载切换，更新提醒、最低版本和iOS保持不变。
- 计划：[Android2235](../../superpowers/plans/2026-10-25-android2235-release.md)。基线9fae702508d07193bd05d13822be3d91806ae16d，包含29384fed消息顺序与0e9a760b缓存修复。
- 工作树C:/Users/Administrator/.codex/worktrees/maintenance-completion/StarChat，分支codex/android2235-release-20261025；父任务独占版本对、上述计划、本记录/报告及current-state新条目。
- 当前状态：环境/版本预检；下一步完成版本占用核对、成对升至0.4.66+2235并冻结构建。精确开始时间见证据基线，主动耗时未知。

## 验收台账

| ID | 要求 | 状态 |
| --- | --- | --- |
| A1 | 最新修复源码与递增版本 | 待版本门禁；共享6410PASS证据待逐输入比对 |
| A2 | 正式ARM64、固定75b31签名、常规重建 | 待构建/验包 |
| A3 | 不推送更新提醒、保留iOS | 未执行任何线上写入 |
| A4 | 可安装包与可复核交接 | 待APK/SHA/签名/报告；真实ARM64设备未连接 |

## 版本与证据

拟版本0.4.66+2235；线上Android文件最高2233、已知iOS候选2234，需以新鲜CI/refs检查收口。固定证书75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff；私钥留本机受保护目录，不进入Git或服务器。

证据根：D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-25/android2235-release/。原主树516状态（含509删除）和全部worktree清单已保存。C盘空闲26.1GiB，D盘65.2GiB；仅发现在线模拟器5556，不推断其ARM64正式包兼容性。

## 阶段与交接

预检进行中；阶段起止由各运行回执记录。不重复执行未变输入已通过的长门禁，不把未执行的平台/真机项写成通过。原IPA2234与既有Android2233发布身份保持；没有新更新提醒授权。
