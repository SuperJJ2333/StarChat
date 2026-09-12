# 断网恢复与离线页面修复实施计划

> 执行：Astra制定与亲审；显式gpt-5.6-terra实施。采用subagent-driven-development及systematic-debugging；用户已要求持续修复，不逐批询问。

目标：修复F1同步停滞，保留本地聊天/朋友圈/本人资料，消除媒体重复加载与误导性断网提示。最新main1fd0354c为基线，不使用2088历史源码。
架构：Matrix负责同步与本地加密数据；业务API仍是好友/资料/资金权威。以账号范围本地快照先绘制，网络异步更新；离线只能打开已验证现存私聊，不建房或以缓存授权资金写入。网络链路可用不等于服务已同步，提示区分离线/连接中/服务不可用。

## 任务和所有权
- [x] F1：Terra sync独占 app_home.dart、matrix_sync_watchdog.dart、最小同步capability适配及新增恢复控制器/定向测试。先核对SDK真实重试与abort语义；测试通知初始化失败仍装配看门狗、断网恢复/切网/前台恢复触发单飞重连、长轮询停滞超时恢复、退出登录后不重启旧client、无重连风暴。允许最小原生/插件网络状态适配，不得改密钥/推送同意门槛。目标网络可达后5s内开始恢复请求，补拉完成依赖服务器与数据量。
- [x] C1/M2：Terra media独占 ui/moments、ui/chat媒体组件、room_page媒体调用区、media_cache与预览缓存及相关测试。先复现重新进入/变更签名URL的缓存miss；稳定可信key、缓存首帧、inflight复用、离线不删成功缓存、销毁释放视图持有资源。测试聊天和朋友圈重进网络计数不增加、磁盘重启复用、同内容不同URL、账号隔离、清缓存后重新下载。
- [x] O1：F1完成释放共享文件后，Terra实现好友页离线发消息。文件coordinated_direct_chat.dart、matrix_direct_chat_adapter.dart、最小facade、direct_chat_failure.dart及测试。现存安全双人加密房间走本地读取；无缓存才协调服务端，网络失败不得claim/create。缓存不绕过实际发送的权限限制。
- [x] O2：F1完成后串行 ProfileController、ProfileRepository、ProfileTabPage装配、profile_page及测试：读取当前账号hydrate结果，后台刷新保留旧资料；无缓存仍展示菜单与明确空态；保存失败保留草稿，成功更新快照，忽略旧请求和dispose后回调。
- [x] N1：O1/O2后统一各页及弹窗网络提示，复用共享组件；自动刷新失败不弹重复模态，主动操作失败弹窗提供取消/重试，错误分类不把403/会话待同步当无网络；重试单飞，恢复状态以实际成功信号清除。覆盖聊天列表/房间/朋友圈/资料/我/媒体浏览。
- [x] U1：Flutter稳定后单独Terra更新frontend演示及packages/ui-contracts相关注册，覆盖离线保留内容、无缓存、重连、主动操作弹窗。使用ui-demo-delivery，Figma退役。
- [ ] V1/D1：Astra亲审实际diff/调用链及测试证据，定向→完整Flutter/analyze/UI契约/前端/verify，如实对比既有失败。核对版本占用后源码构建→APK重建→固定签名→语义/哈希核验，Mi6 install-r保留数据；用户功能自测。不push/部署/迁移、不更改设备WiFi设置。

## 成本与边界
M3跨账号不共享是隐私边界，不消除；跨设备秒传不能由本地缓存假定，需要服务端密文去重协议证据再决定。聊天与朋友圈共享内容对象必须保持账号/来源/权限与已批准ADR0060一致，不能将公开digest当授权；不把未知视频原件等同于缩略图。M2以消除重复读/解码和有界缓存为本批可执行项，debug PSS不是release性能结论。100群规模/8h压力/真实双账号等缺环境场景提供可执行用例与标准，不在生产造数。

## 验证命令
Flutter定向测试按执行者实际新增路径记录，执行前先RED，修复后GREEN；flutter analyze；flutter test；py -3.12 scripts/verify_ui_contract.py；frontend npm test；pwsh -NoProfile -File scripts/verify.ps1（先环境预检）。原始日志仅在docs/verification/artifacts/2026-09-12/offline-recovery。每批记录真实exit与输入身份，不用既有通过代替本次。

## 细化方案与验收（10:57+08）
F1补充：root亲读SDK发现旧_sync Future的whenComplete不验证身份，abort后迟到响应可清除新_currentSync并再开环。已批准最小sync generation保护及真实SDK可控HTTP回归（不更改加密算法）。SDK原processing在空响应判错前发出，因此用户可见已恢复只能使用有效finished，不能仅凭processing/transport。
M2：legacy聊天预览缓存原随RoomPage.dispose清内存，重进从盘解密产生新MemoryImage及placeholder。批准在既有字节预算内保留同账号同房间encoded bytes池，页面只释放消费者；清缓存/切号使池失效，不留widget/ticker。
M3：批准本地授权下载后计算内容SHA并写入公共MediaCache、object-reference alias保留账号与来源约束；既有Manager命中可迁移后移除对应旧项。验收对象数/网络数而非只看文件名。必须验证清缓存并发不回填、账号隔离、URL轮换、进程重建后的alias磁盘复用；不新增跨设备上传API或跨账号共享。

## 后续实施细化与审查用例（11:20+08）
O1：新增显式 local-only 查找接口，不复用会调用 requestParticipants/join 的原 findExisting。m.direct 指向已加入且加密的房间，本地 join+invite 恰为本人/目标，participantListComplete 且非 partial 才通过；必要时只读 SDK database.getUsers。gateway 在 canonical 查询前尝试安全缓存快照，未命中仍走原服务端协调，不以异常推断不存在。验证：已有房间离线 API 调用0、缺失/不完整/第三人/未加密/邀请态不走离线捷径、原重复点击与协调幂等套件；RoomLease.attach 当前仅 getRoomById，无联网等待。
O2：ProfileController 增加可选 readCachedProfile/persistProfile 回调以隔离仓储；ProfileTabPage 接入当前账号 repository.hydrate/profile 及公开写入方法。读库失败仍可网络刷新，网络失败保留旧资料/编辑草稿；世代与 dispose guard 防旧加载覆盖新保存。仓储更新只替换本人资料、保留联系人并使旧 profile refresh 失效。菜单列表不以 profile != null 为前提，无资料时仅身份区显示加载/重试。验证：离线读库首帧、无缓存仍进设置/朋友圈、刷新失败旧资料不消失、旧加载晚于保存不覆盖、销毁后无通知、写入后重建仓储仍保留资料。
N1：使用会话所有者绑定的可读网络状态，transport 表示候选，Matrix finished 才表示已恢复。统一提示覆盖共享页面 scaffold，置于导航下不遮盖内容；unknown/connected不占空间，offline/connecting/serviceUnavailable文案分别明确。自动刷新不自动弹模态；主动操作失败使用取消/重试，单飞重试，权限/业务失败不得错报断网。退出旧账号必须解绑监听且不能覆盖新会话。验证真实组件状态切换/路由推入、重复触发弹窗只有一个、重试不重入、销毁与换号不残留。UI HTML 与注册同步后验证。
缓存审查新增：升级前朋友圈 legacy CacheManager 命中必须能断网迁移；仅内存世代不足以阻止 clear 后新 provider/新进程复活未知旧文件，须持久账号撤销边界。延迟 HTTP 在 clear 后落盘也需清除，且失败的附加 cleaner 不能跳过原聊天对象删除。
