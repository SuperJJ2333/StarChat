# 2194 性能、静音与媒体下载实施计划

规格：../specs/2026-09-30-mobile-perf-mute-media.md
基线：main 8e173178，移动源码 05c05793；工作树 mobile-perf-mute-media-2194。
用户已授权自主计划与发布。按 subagent-driven-development 执行；每次仅一个实施子代理，主代理可处理独立文件。临时材料按根 AGENTS 存放 docs/verification/artifacts/2026-09-30/mobile-perf-mute-media/，替代技能默认临时目录。

全局约束：不提交密钥/日志正文/令牌；E2EE 解密和缓存仅客户端；保留既有稳定签名、发送幂等和缓存失效规则。不得修改并行后台任务或清理其他工作树。所有修改在隔离工作树。接口冲突先在记录裁决。

## Task 1: 静音全链路
归属：conversation_preferences.dart、group_chat_info_controller.dart、group_chat_info_page.dart、mute_exception_policy.dart、通知呈现相关文件及对应测试；不编辑 matrix_e2ee_client.dart 或 app_home.dart，由主代理集成必要调用。
先写失败测试：静音写入真实 SDK 推送规则；取消静音恢复；离线失败重试；快速切换最终模式；普通静音消息无提示；进入静音例外默认关闭。
实现账号域内持久同步推送规则，与偏好写入统一串行。不要靠陈旧 SDK 推送状态提前跳过写入，保护其他不属于本应用的规则。处理既有静音偏好迁移/投影。定向测试并提交拥有文件，生成 task-1-report.md。

## Task 2: 动画负载与 GIF
归属主代理：media_activity.dart、budgeted_media_image.dart、room_page.dart、Matrix UI 事件合并辅助类和 matrix_e2ee_client.dart 的 sync 通知、对应性能/媒体测试。
先测默认预算能同时运行 4 个可见 GIF，显式预算与离屏暂停仍正常；消息 burst 合并 UI 快照通知且最终状态不丢失；键盘/输入变化保留消息行和缓存。
移除默认 2 GIF 上限，保留可见性/后台开关。消息 UI 快照按帧合并但不丢解密/发送事件。缩略图完成只刷新时间线；消息行缓存按实际呈现依赖失效，避免无关父页面更新清空所有缓存。定向回归后记录证据。

## Task 3: 收件媒体与后台
归属实施代理：新建账号域预下载服务/公共接口、app_home.dart、Moments 缓存/预取文件、Android/iOS 原生后台下载集成及对应测试；matrix_e2ee_client.dart 仅交由主代理根据明确补丁请求集成，避免并行编辑。
从既有解密事件/收件快照发现媒体，复用已有 MediaCache/RoomImagePreviewCache 内容键与下载权限、调度器；无需页面挂载。有界并发和取消，后台工作不得占满交互槽位；媒体缩略图缓存按账号持久化。朋友圈从已有服务提取新媒体，不消费未读状态。
后台/锁屏：复用 Android 既有服务并确认挂起时原生下载；iOS URLSession 后台任务仅接收受信 URL/必要授权，私有目录、账号取消，原文加密内容仍由客户端安全解密。先红后绿覆盖去重、失败重试、注销迟到回调、闪照排除、缩略图重入、生命周期。平台编译与系统限制必须如实记录。

## Task 4: 整体审查、门禁与发布
冻结前加入用户已授权的内存专项：主代理拥有 matrix_e2ee_client.dart、解密预览缓存及回归；实施代理先只读审计媒体字节缓存，明确所有权后按测试先行修复。证明4500条持续收件不再使预览副本无界增长，同时验证最新预览、撤回、账号连续性与旧记录读取。媒体只修复可证实的无界成功保留/释放缺陷，不降低可见GIF同步播放要求；无真机不得声称RSS平台验收通过。
主代理整合，先规格后质量/安全。聚合服务器 request timeline 定位限流热点；保留长轮询正常等待解释。运行 focused、全 Flutter、analyze、预检后 verify.ps1；按变更影响复用未变输入证据。
核对线上版本/构建号占用，再冻结版本。Android 按 android-apk-rebuild.md 打包、固定身份签名、验证并发布更新弹窗；iOS 按现有 CI 生成候选后交回签。更新独立任务与 current-state，合并 main 和清理仅本任务分支；保留外部任务。
