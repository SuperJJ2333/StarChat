# 在线房间刷新与 Mi6 Debug2168

> 2026-09-26 集成交接：下文为当次交付历史；其中“未提交/未合并/未推送”及旧 Debug 下一步只描述 2026-09-24 的状态。对应移动实现已随分支集成进入 `main f820d704`，见[集成记录](../workflow/tasks/2026-09-26-branch-integration-main.md)。本文此后补入版本控制，不表示重新构建、安装或发布；当前设备及生产状态以最新任务的实测为准。

## 范围与根因

用户报告0.4.6在线收键盘、退出房间、进入其他房间卡顿，断网顺畅。本次落实其批准的三项优化：

1. 逻辑时间线原来对全局sync无条件通知当前房间；无关房间与回执活动也可能触发刷新。改为首次挂载/实际历史来源新增通知，当前房间消息、解密、成员、权限、偏好状态保留独立通知。成员投影只在成员/权限/排序变化时失效。
2. 会话快照原来连续请求并与导航动画竞争UI线程。改为32ms合并窗口、单飞加载，路由进出期间暂停非紧急快照计算/发布，恢复后取最新。首个本地缓存快照立即展示。
3. 表情backend原来绑定房间租约，进不同房间重复加载。改为账号/SDK会话级backend和single-flight刷新；后台成功缓存30秒，vault事件修订号变化立即失效，显式刷新仍强制更新。换账号/会话旧backend不可用。

这些是客户端同步刷新与计算路径问题的代码证据，不等同于真机端到端帧时结论。Debug性能不代表Release性能；仍需用户在线重复原操作确认。

## 候选身份与整合

- 工作树`.worktrees/online-room-refresh`，分支`codex/online-room-refresh`，基线8ed729a18d1f48ddf8738656765c69f15a14d8b8。
- 输入包括主目录尚未发布的冷启动/头像/预览修复；baseline.json记录原始身份。
- 保留设备2167已有公告、账单、客服及朋友圈修复，43移动文件来自`.worktrees/mobile-feedback-2165`，另补原朋友圈请求fixture。合并记录feedback-integration.json，原文件和本次修改前快照均保留。
- 本次核心实现5个文件：matrix_e2ee_client.dart、room_page.dart、matrix_home_page.dart、matrix_home_snapshot_refresh_coordinator.dart、matrix_emoji_vault.dart。
- 源码逐文件哈希candidate-source-sha256.json。独立整合候选不自动覆盖主目录其他任务文件，也未修改来源反馈工作树。

## 验证与审查

证据目录：`docs/verification/artifacts/2026-09-24/online-room-refresh/`（原主工作树的忽略归档，不随 Git 交付）。

- 三批RED/GREEN：batch1/2/3日志；真实SDK当前/无关房间通知、20次成员读取复用、真实Cupertino导航动画20次同步合并、表情跨房共享/换账号隔离/失败重试覆盖。
- 规格审查后质量/安全审查发现当前房间accountData遗漏、表情初始化修订竞态，分别新增失败测试并修复（review-red/green）。
- 整合复审发现已认证冷预览客服徽标偷偷发起lookup；新增RED记录实际请求`/api/v1/support/identities/lookup`，修复后预览零业务请求。最终限定复审无剩余blocker。
- 最终保护与视频合同专项21通过；之前整合专项29通过。
- 初次全量6个失败已分清：5个首快照延迟回归已修复；1个旧生命周期夹具按调用奇偶返回物理重复房间，与生产逻辑快照契约不符，改显式状态迁移并保留唯一逻辑房间/新增群断言。
- 第一次整合全量4071通过/9条件跳过/1失败：缺少来源树composer_requests.json测试fixture，已原样补齐，不修改生产契约。
- verify.ps1实际启动后在未变后台全量阶段中止，不声称完整脚本exit0。未改后台复用已有证据，8ed相对12ded后台增量补跑8通过；移动边界108通过/1跳过，UI契约403screens、API导入/AST、迁移/OpenAPI/Compose通过，verify-impact.log exit0。

## 交付进度

已交付0.4.9+2168，最终Flutter全量/analyze与APK构建安装结果见下文。实际Debug/ARM64、Apktool2.12.1完整重建、固定签名。Mi6原0.4.8/2167，首次安装2026-09-20 09:35:24，安装前APK SHA已核对与2167记录一致。只保留数据覆盖安装，不正式发布服务器/官网/iOS。

### 最终源验证（04:12）

Flutter全量 **4073通过、9条件跳过**，analyze **No issues found**，均exit0。锁文件版本及内容SHA不变（offline pub get的镜像URL差异已严格核对并恢复原文件）。原verify已完成的仓库/部署策略、模板、配置渲染、infra144、getui28、bot9均通过；日志中已有Starlette与Pydantic依赖弃用提示，本次未改相关服务依赖。

### 构建阶段

04:12开始，源Debug Gradle构建158.7秒通过；源APK检查debug kernel=true、ARM64唯一架构、无AOT。1668个移动源码文件逐项复核与测试身份清单一致（source-freeze-check.txt）。构建使用现有Flutter/Java插件，保留其Kotlin迁移及Java弃用/unchecked编译提示，不将提示伪称分析器错误或本次新引入问题。APK重建及最终验证在独立C盘证据目录进行。

### 04:17 Debug构建与设备交付完成

- 最终包0.4.9/2168，145494315字节，SHA256 `1a2bb53e47191ae0b51192ae30bbdbba251b95ee90aaa55251fe73d7ded07d9a`。
- 实际Debug kernel、ARM64唯一ABI、无AOT；固定签名证书75b31c66…ba61fff，签后对齐通过。
- Apktool重建前后27317个smali类语义一致，339项原生库/Flutter资产字节一致，清单语义一致；资源与DEX确实重建。
- Mi6 `cbd0156b` 执行install -r成功，版本2168/0.4.9及DEBUGGABLE核对通过，设备base.apk SHA与最终包一致；首次安装时间仍2026-09-20 09:35:24。启动成功，进程存在，安装后的短时启动检查无新应用崩溃记录。
- 已完成授权的Debug交付。未卸载/清除数据，未发布官网、服务器、iOS或推送Git。
- 最终APK与构建全证据位于 `C:/Users/Administrator/.codex/visualizations/2026/09/22/01a0ca75-6de7-7150-99e8-2bc78f7347a3/docs/verification/artifacts/2026-09-24/android-debug2168/`；关键JSON另复制到本报告证据目录。
- 下一步：用户在联网状态重复输入→收键盘→退出→进另一房间，并确认消息、成员、表情刷新正常。没有采集真机帧时，不宣称卡顿已在设备上量化消除。
