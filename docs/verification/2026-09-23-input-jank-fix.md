# 输入卡顿客户端修复验证（2026-09-23）

用户报告 Android v0.4.0 在弱网/群消息突发下输入迟缓，批准执行 [调查方案](2026-09-23-android-040-input-jank-audit.md)。本次修复本地索引与时间线热路径；未进行 APK 构建、设备安装或服务器部署。

## 身份与边界

候选 .worktrees/input-jank / codex/input-jank，基线 1baaf36e，加上此前21个移动端已修改/新增文件（保持逐文件SHA不变）。本轮拥有9个产品源码/测试文件，清单在 artifacts/2026-09-23/input-jank/integration-manifest.json。Flutter3.44.9/Dart3.12.2，Windows/PowerShell7。离线pub get仅改镜像URL，217个解析版本均未变化；原pubspec.lock已恢复并与主目录SHA相同。未更新依赖。

## 改动

1. RoomPage同步通知只提交有界当前窗口，历史由 RoomSearchIndexPump 惰性分片。每片最多64条、目标2ms、片间4ms让出事件循环。计时预算不包括无法抢占的单条投影和最终批次回调，不能称硬实时2ms保证。
2. 删除旧“先标记seen再取消Timer”的提交路径。按事件ID合并待处理状态；失败不确认，源读取失败重开迭代器。失败旧正文与新撤回同批只保留权威新状态，防止撤回复活；账号epoch失效/页面销毁停止。
3. 内存边界：pending2048、retry64、overrides2112、known60000。过载交给可重读的权威已加载source重扫，撤回优先；未加载历史仍依赖既有加密本机数据库回填。本队列不是不可重放任意流的持久化保证，也没有新明文落盘。
4. GlobalSearchIndex使用ID映射与时间/ID有序树，增量更新不再复制、去重、排序整房间历史；同ID新正文可替换旧正文，容量按最旧淘汰，删除同步更新两种结构。
5. 逻辑时间线仅排序新增/替换行，再与保留行线性合并；未变化快照保持对象身份。未假设SDK来源List不可变，也未跳过成员/权限变化。单源仍有O(N)扫描；不能称已消除全部主线程负载。

## 红绿与审查

- baseline：原增量索引和输入隔离用例通过，日志 input-jank-baseline.log。
- red-search：旧索引同ID新内容未生效（No element）；新pump缺失的接口回归失败，exit1。
- red-merge：新预算合并接口缺失，exit1；21项合并/逻辑时间线后续通过。
- red-source：源读取失败后不恢复的行为失败，修复后通过。
- red-recall：独立审查提出窗口外撤回/失败旧写入复活，实际复现失败；修正按ID最后权威状态合并后，pump7项通过（green-pump.log）。
- 搜索模块早期69项、聊天离线/输入页面23项通过。新增页面回归：30批消息、中文拼音composing/selection/controller/FocusNode不变，最终可提交汉字；这是widget层行为，不是真机IME延迟测量。
- 1万条模型的计数回归：未变化0次排序比较；单条新增至多1万次合并比较；验证顺序/删除/重复ID首来源优先与对象复用。这不是手机吞吐量或掉帧提升百分比。
- 独立审查先规格后质量：容量和单源契约意见已修订；P1失败重试撤回问题已红绿修复，最终相邻逻辑复审通过。窗口外撤回仍需要后续历史分片处理，不声称立即一致。

## 最终门禁

最终 `flutter test --no-pub --reporter expanded`：3932 passed，exit0，4分21秒；`dart analyze`：No issues found，exit0。9个源码/测试文件已逐SHA回填主目录，与经过完整门禁的候选相同；先前21个移动修改逐SHA保持。移动边界pytest：108 passed/1 skipped（3.61s），UI契约、RepositoryPolicy exit0。scripts/verify.ps1已阅读并按mobile-delivery-workflow影响规则选择门禁：本轮后端/数据库/OpenAPI/infra输入未修改，复用同源staff-console完整verify exit0（2684/67，infra144/getui28/bot9及协议迁移），不重复后端长测试。候选仅移动变化；主目录既有诊断/红包修改不被覆盖。

中途一次组合专项测试被主动中止（exit -1），不作为通过证据；先前analyze发现3条style提示已修，最终静态分析通过。完整测试日志保留在flutter-full.log。

## 尚未证实的部分

用户补充设备Redmi K80、App v0.4.0；Android系统版本/输入法/完整build尚未知，未采集设备profile trace。此次消除了确认的索引丢批、旧内容更新缺陷，并降低计算复杂度和单轮历史处理量；不能直接宣称用户手机输入卡顿已彻底消失。网络恢复时SDK投影/成员/解密/存储/绘制占比需要真机测量后继续针对性优化。

下一阶段是同源Android候选构建与实际设备验证；未改版本号、安装包、官网或生产服务。安全、账号恢复、容灾仍暂缓。

完成观测：2026-09-23 19:34:33 +08:00 全量测试exit0；回填时间见integration-manifest。19:11:50起始观测至本次回填约23分钟，主动开发/工具执行交错，未单独记录精确分摊。没有签名或外部服务等待；中止组合专项造成的返工不算有效通过。
