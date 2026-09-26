# 在线房间刷新执行计划

依据用户本轮选择与[设计](../specs/2026-09-24-online-room-refresh-design.md)，在隔离工作树 `.worktrees/online-room-refresh` 内执行，基线8ed729a1并复制既有冷启动源码候选。文件所有权root独占，其他任务文件不回滚。回填前比对主目录基线哈希。

## 批1 房间更新范围与成员缓存

- 所有权：`matrix_e2ee_client.dart`、`room_page.dart`及新增`test/performance/room_scoped_refresh_test.dart`。
- RED：从诊断真实SDK夹具建立无关消息/仅回执不得额外回调的断言；相关成员、解密、消息和历史来源新增仍通知；成员快照在普通消息期间复用。
- GREEN：关联来源有变化才通知；当前房间状态及相关解密单独监听；成员投影按状态失效、复用列表，dispose取消新增监听。
- 验证：新用例、logical timeline、成员投影、factory、离线打开及输入性能回归。

## 批2 会话快照调度

- 所有权：`matrix_home_snapshot_refresh_coordinator.dart`、`matrix_home_page.dart`和新增调度测试。
- RED：时间窗口内请求合并；暂停期间不启动/发布，恢复只发布最新；失败、dispose与账号变化不悬挂等待者。
- GREEN：有界合并及暂停恢复，绑定路由animation/secondaryAnimation状态；保留初始缓存显示。
- 验证：coordinator、home snapshot、conversation projection与路由动画widget测试。

## 批3 账号表情缓存

- 所有权：`matrix_emoji_vault.dart`、`matrix_e2ee_client.dart`、`room_page.dart`及新增缓存测试。
- RED：两个房间共享backend；原房间取消后可用；换账号/会话旧backend拒绝；并发刷新一次、成功后台复用、失效与失败重试。
- GREEN：会话级backend，刷新合并与短期成功缓存；事件变化失效；原有编辑、上传、加密检查保留。
- 验证：emoji vault、媒体/房间生命周期及新测试。

## 最终检查

- 顺序进行规格审查、质量/安全审查，修正发现；运行受影响集合及Flutter全量、analyze。
- 预检verify环境，按移动交付规则复用未变化服务端门禁，补跑实际影响的移动边界/仓库门禁；保留不相关失败及跳过说明。
- 保存RED/GREEN日志、源码与依赖哈希、工具身份和计时。按基线哈希安全回填本任务文件，不覆盖其他变更。未打包或发布；真机profile/release帧时间作为后续验收项。

## 用户追加的Debug交付（2026-09-24）

用户已授权Mi6安装Debug。执行0.4.9+2168真实Debug ARM64源构建、Apktool2.12.1重建、36.0.0对齐、固定签名及语义/资产核对，再保留数据覆盖安装设备cbd0156b。保留其2167已有修复，集成来源与合并结果另存证据。源码保留在当前隔离候选，本轮不自动覆盖主目录其他任务变更；不发布官网、服务器或iOS。
