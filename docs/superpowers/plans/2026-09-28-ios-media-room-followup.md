# iOS 媒体与房间体验修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development or executing-plans to implement task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 完成本次八项体验修复，交付保留诊断能力的待企业重签 IPA。

**Architecture:** 朋友圈使用账号绑定的持久任务队列与可选小封面；房间通知订阅本地查看状态；本地历史投影供检索与日历复用；公告按引用及权限版本管理；转发在实际准备时预留媒体内存。所有原生/共享接线串行集成，保持 E2EE、账号生命周期和服务可见范围。

**Tech Stack:** Flutter3.44.9/Dart3.12.2、Matrix SDK/SQLCipher、Swift/iOS、FastAPI/SQLAlchemy、GitHub macOS15/Xcode。

设计已由用户回复“按推荐方案实现”批准，包括小封面接口；无需重复确认实现。服务发布、签名包分发分别交接，不将代码批准当生产发布授权。

## 0. 基线与并行归属

- [x] 独立 codex/ios-media-room-followup 工作树，f433381a 移动基线；固定依赖四文件45项通过。保持 PUB_HOSTED_URL=https://pub.dev，pub get --enforce-lockfile，测试使用 --no-pub。
- [ ] task/spec/current-state 更新为已批准实现，记录各阶段起止及真实退出码。
- [ ] 朋友圈实现拥有 features/moments、ui/moments 媒体缓存/视频tile、core/business_api_client.dart 的任务会话/封面小增量、服务 moments/media 小封面及新增迁移/契约与专属测试。不得编辑 AppHome/main、room_page 或 Matrix 客户端。
- [ ] 历史实现拥有 local_room_history_search.dart、新本地投影模块、chat_search_page.dart、chat_search_query_controller.dart、matrix_e2ee_client.dart 仅搜索/月历接线及专属测试；共享客户端归还前 root 不编辑该文件。room_page 搜索接线提供独立补丁由 root 应用。
- [ ] 公告实现拥有 group_announcement_page.dart/service.dart 和专属测试；room_page 稳定scope接线提供补丁给 root。
- [ ] root 拥有通知/read-state、原生通知清除、转发coordinator、room_page、AppHome/main队列接线、版本/CI/构建/文档；Matrix客户端收到历史任务归还后再改转发。

## 1. 朋友圈持久发表队列与同策略媒体、封面

**Files:** 新 features/moments/moment_publish_coordinator.dart 与任务store/媒体准备适配器；现 composer/moments_page/models、moment_media_cache/video_tile；BusinessApiClient；服务 moments/media API/service/model、可选封面迁移及 OpenAPI；对应 Flutter/API/PG 测试。

- [ ] 先添加行为失败用例：阻塞上传 Completer 后发表页能退出、重开失败任务可重试且同幂等键、登出/切号不能使用新会话、草稿清理失败仍保持发表成功。
  ```dart
  final upload = Completer<void>();
  await tapPublish();
  expect(composerIsVisible(), isFalse);
  expect(publishTaskIsPending(), isTrue);
  upload.complete();
  await settleQueue();
  expect(publishedCount, 1);
  ```
- [ ] Run `flutter test --no-pub test/features/moments/moment_publish_coordinator_test.dart test/features/moments/moment_composer_page_test.dart --reporter expanded`，保留预期red日志，再实现。
- [ ] 定义不可变发布任务（id/account/body/visibility/material references/stable idempotency/phase）；沙盒本地素材和任务原子保存，不保存token；接纳后页面退出，成功/失败状态留朋友圈重试/取消入口。
- [ ] 统一prepareGalleryMedia与视频transcodeForChat，最终≤20MiB、空/GIF规范、惰性读取；局部静态图压缩保留。准备/传输有界，账号切换撤销/恢复只同账号。
- [ ] 网关每请求验证捕获sessionepoch/account，不允许旧任务在refresh/切号后借用新凭证；同账号合法refresh通过现有刷新流程完成。
- [ ] 小封面为可选媒体引用，上传验证真实图片/体积、与视频发布者/动态可见范围绑定；旧DTO兼容，历史缺封面使用已缓存视频抽帧，无静默完整视频下载。新tile按可见度加载小图、去重/失败冷却/账号fence。
- [ ] API失败测试覆盖他人media_id、图片伪装、无权viewer及旧无poster请求；扩展迁移隔离恢复/回退验证，不做破坏性降级。
- [ ] 专项green、lint/analyze，先规格再质量/安全审查；提交仅所属文件。交 root 队列AppHome生命周期与刷新公开接口。

## 2. 本地历史投影、二态月历、自动续页

**Files:** local_room_history_search.dart、新本地投影/date snapshot模块、chat_search_page.dart/query_controller、matrix_e2ee_client.dart 搜索接线与专属测试；room_page 接线 root 应用。

- [ ] 写red：knownEmpty不可点、hasMessage使用本地anchor；读取未完成/失败不把unknown标空；不连续 live/context 不吞覆盖；两个保留来源正确合并。
- [ ] 写red：滚动、短屏、空continuation自动续页，无查看更多按钮；查询代际、无进展cursor、失败重试；缺失event短投影页不误判穷尽。
  ```dart
  expect(dayWithNoLocalMessages.onTap, isNull);
  await scrollNearBottom();
  expect(nextPageCalls, 1);
  expect(find.text('查看更多'), findsNothing);
  ```
- [ ] Run 受影响 `flutter test --no-pub test/ui/chat/bounded_search_feedback_test.dart test/features/matrix/local_room_history_search_test.dart` 及新增日期/快照测试，保留red。
- [ ] 构建账号/room来源/revision所属的本地全消息投影快照；分批读取/yield，日期含可显示媒体，撤回/清空/解密/来源变化增量失效；现有SQLCipher公接口读取，不复制明文到业务API。
- [ ] 关键词复用投影，日期用已知本地anchor，月级加载/错误另处理；去掉正常按钮，自动推进有界单飞，真正异常保留重试。
- [ ] 10k/100k合成稀疏命中实验输出读取/投影次数、复用及时间，证明重复查询不重读全历史；不宣称未测真机速度。
- [ ] green、analyze/规格→安全；归还共享Matrix客户端并给root房间接线补丁。

## 3. 公告管理和持久关闭

**Files:** group_announcement_page.dart/service.dart 与测试；room_page scope patch root 应用。

- [ ] 写red：确认框打开后无关sync仍可继续编写；公告引用改变/失权/切号仍拒绝；失效引用、旧密钥缺失可删除/重新加密发布，普通成员拒绝。
- [ ] 写red：真实lease入口关闭、退出、重进/重启相同公告仍隐藏；新引用显示、换账号不继承。
- [ ] Run `flutter test --no-pub test/features/matrix/group_announcement_member_test.dart test/features/matrix/group_announcement_draft_banner_test.dart` 及新增病例并确认预期失败。
- [ ] 操作有效性用service identity/current reference/current actual power-level；删除公开空引用与加密正文发表分别检查，正文始终E2EE，不放宽Matrix写权限。
- [ ] 明确管理员删除/修改入口，room scope=`account+room`与公告版本共同持久；root应用真实room_page接线。
- [ ] green、领域/规格→安全；如果实现改变受保护权限/E2EE规则先提供ADR，无明文回退。

## 4. 房间通知/角标即时消除、批量转发与选中背景

**Files:** conversation_read_state.dart、notification_coordinator.dart/system presenter及native room notification matcher；iOS AppDelegate/MainActivity必要接线；Matrix outgoing coordinator、matrix_e2ee_client.dart转发、room_page、UI选中背景及相关测试。

- [ ] 通知red：App内打开A清A通知并重算badge，B通知/来电保持；展示等待中打开房间不复活；旧badge快照不得覆盖新值；账号切换解绑。
  ```dart
  readState.setRoomOpen('A', open: true);
  await settleNotifications();
  expect(canceledIds, contains(notificationIdForConversation('A')));
  expect(canceledIds, isNot(contains(notificationIdForConversation('B'))));
  expect(badgeCount, unreadOfB);
  ```
- [ ] Run 通知coordinator/read_state专项red后增加公开读状态事件，coordinator串行清除/角标刷新；native iOS按userInfo room_id清已送达，保持其他通知。
- [ ] 转发red：10×20MiB媒体元数据批量可接纳，真实准备期间占用≤原128MiB/有限并发；每附件越界拒绝；大扇出分批、重试不重复已成功目标。
- [ ] UI red：选中持续高亮，取消恢复，复用引用高亮色/无障碍selected；行点击切换。
- [ ] 改`retainedBytes`为冻结元数据真实成本，`preparationBytes`为附件上限，保留队列字节/数量预算；任务扇出有界协调，不简单提高限制。
- [ ] 原生门禁验证通知匹配/顺序规则，iOS平台验证实际UNUserNotificationCenter桥；Android相关契约/编译，系统锁屏门槛回归。
- [ ] 专项green、analyze、规格→安全，提交所属文件。

## 5. 集成、iOS候选与企业签名交接

**Files:** AppHome/main队列接线、相关测试、ios纯核心测试/Runner tests、.github ios候选workflow、版本两源、task/report/current-state。

- [ ] 集成公开coordinator生命周期：登录/恢复加载当前账号任务、登出撤销、朋友圈刷新；应用级owner与页面生命周期分开。
- [ ] 修正NativeCore测试误含UIKit：纯Foundation/Security测试独立文件、复制其所依赖纯Swift源；iOS UIKit测试进入iOS target/模拟器验证，不能跳过。
- [ ] 从只读预检的最新远端workflow保留现有门禁，只增独立codex候选分支触发；signed/compatibility不启TestFlight，显式`--dart-define=CHATFLOW_PERFORMANCE_METRICS=true`。
- [ ] 版本先核对线上/CI占用，用bump_version同步pubspec/app_config，记录iOS新候选版本与build，不改Android线上设置。Run版本契约失败/green及两端平台隔离测试。
- [ ] 最终共享全量Flutter测试/analyze、受影响API/迁移/原生门禁、UI契约、适用scripts/verify.ps1（先环境检查）；基线不足/失败如实记录，不能导入生产秘密或假称全绿。
- [ ] 先完整规格审查，再质量/安全审查，关闭本任务发现。冻结源hash、lock/tool版本与候选分支提交；漂移保护回填所属源码，保留主目录其他任务修改。
- [ ] 推送仅候选分支触发macOS构建；读取确切run/source、首个失败定位后重试受影响job，保留日志。不创建新用户任务。
- [ ] 取回IPA构建工件至本任务证据目录；验证版本/Bundle ID/SQLCipher/APNs音频VoIP/包源与资产，提供大小/SHA及待企业重签交接。最终签名确认及真机与分发为后续阶段，不伪造已分发。
- [ ] 小封面服务完成候选报告、兼容回退及鉴权/可见范围审查后单独请求发布授权，等待期间iOS可继续独立构建；旧服务缺字段客户端正常兼容。
