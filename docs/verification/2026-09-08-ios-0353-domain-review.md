# iOS 0.3.53 领域与规格复审证据

日期：2026-09-08（Asia/Hong_Kong）
审核角色：独立领域/规格审核；本文件不是独立 Quality/Security 实现审核或真机验收报告。
审核方式：代码只读，唯一写入为本证据文件。

## 范围与依据

- 已批准产品设计：docs/superpowers/specs/2026-09-08-ios-0353-background-calls-design.md。
- 已批准实施计划：docs/superpowers/plans/2026-09-08-ios-0353-background-calls.md。
- 产品不变量：docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md。
- ADR：隔离源码 docs/adr/0011-ios-background-call-wakeup.md。
- 隔离源码：docs/verification/artifacts/2026-09-08/ios-0353/source。
- 原生复核基线：6ac006f0；网关复核基线：78a234fd；Dart 复核包括 root 当前尚在验证中的同步 _cancelRequested 修复。

## 结论

本次最终领域与规格复审通过，已指出的领域阻塞全部关闭。领域侧同意按已批准计划推进独立网关部署及候选构建；此意见不替代独立 Quality/Security 实现审核、root 最新测试门禁、macOS 编译和设备验收。未完成的实际设备行为不得标为通过。

## 已确认边界

1. 网关仅接受显式通话唤醒请求，不订阅或把所有 m.room.encrypted 事件当作 VoIP。每个请求以固定 Synapse whoami 验证 Matrix 用户/设备；创建与提前取消核验实际加密双人房成员。服务端及 APNs 不获取聊天正文、SDP、媒体、房间密钥或恢复密钥。网关不修改业务登录、RBAC、资金接口或数据。
2. 接收者账号/设备资格经固定 admin 只读接口核验；不将设备存在误称为完整的接收者 token 撤销验证。此限制已在 ADR/README 明示。媒体仍由当前客户端和解密后的 Matrix 会话授权。
3. HTTP 网络请求在 SQLite 锁外进行；sending/delivery_unknown 在有效期内允许接听。晚到的发送结果不覆盖 answered/ended；取消只用普通 APNs。取消任务在已提交的响应之后执行，不把附属推送失败变成接听授权失败。
4. room_id + call_id 双标识贯穿网关、Dart 和原生 UUID/墓碑/endCall。native stop 的批量清理由会话 owner 限制。
5. native 下行事件捕获 owner，Dart 严格拒绝其他 owner；首次冷启动尚未归属的 pending 仅在首次 ready 时归属当前 owner。已归属事件不会换绑。旧 owner 即便 room/call 相同也不能触发新会话动作。
6. pending mute 与 answer 独立存放。cold ready 不等待 HTTP token 注册。有效 end 同步标记 _cancelRequested，并使 backend answer generation 失效：既覆盖 native 呈现等待期间，也覆盖 HTTP claim 等待期间；返回后不能重新接听。
7. answerAndConnect 对不可用、拒绝、冲突失败关闭，媒体连接前再次检查当前通话与 generation。仅已批准的 404 无唤醒记录保留旧客户端兼容路径。
8. registration_id 隔离新旧路由。注销/410/取消/投递按 owner 与既有身份精确匹配；absent 或 mismatch DELETE 同样退休旧 owner，旧 PUT 在退休窗口内被拒绝。退休记录有效期 3600 秒、每设备 128 条/全局 100000 条上限，并有清理。此窗口用于已限定时长的在途请求，不是永久撤销标识。

## ADR 0011 Keychain 领域批准

仅 liuhetong.matrix_database_key.v1 与 liuhetong.business_session.v1 使用 AfterFirstUnlockThisDeviceOnly。原生 SecItemCopyMatching 固定服务与两项名称，不用 accessibility 搜索过滤；只有 errSecItemNotFound 代表不存在。旧条目成功读取后，SecItemUpdate 仅改 accessibility，读回核验原字节与身份属性。失败不删除、不添加替代条目、不生成新数据库密钥。新条目仅在确证缺失时添加。正常显式会话写入/注销仍限定这两项。

FlutterSecureStorage 9.2.4 原写回机制曾因 SecItemUpdate 失败后的 delete/add 回退而被拒绝，其 read 的 synchronizable 再查亦可能掩盖初次错误；当前这两项直接使用受限原生通道。恢复密钥、注册设备密钥和其他项目仍保留原策略；SQLCipher 与 E2EE 服务器边界未改变。扩大首次解锁后锁屏访问窗口的风险已在 ADR 明示，领域批准限于此明确范围。

## 验证证据与限制

- 本审核者实际运行网关：python -m pytest tests -q -p no:cacheprovider --basetemp=D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-08/ios-0353/gateway-domain-final-78a234fd；退出码 0，42 passed in 13.12s。
- 已阅读 Dart 针对旧 owner 同通话拒绝、pending mute、cold ready、HTTP claim 失败关闭、native end 取消，以及新加 presentation 阻塞期间 end 的回归测试。root 报告此前 focused 22 项通过；本审核者没有重复执行当前 root 正在运行的最新 Dart 门禁，不将其结果冒充独立实测。
- 本审核者未执行 Swift/macOS 编译、XCTest、Linux 容器/flock、生产 Synapse/APNs 或 iPad 升级锁屏冷启动/音频/PiP 验证。候选发布与功能验收必须引用各自真实结果。

## 关闭的复审问题

- 原网关全程持锁使接听等待至过期：已改为事务预留、网络在锁外。
- 模糊 APNs 超时把实际来电标 failed、无法接听：已增加 delivery_unknown。
- 原生 endCall 忽略 roomId 或缺 callId 时全量结束：已改双标识严格匹配。
- 原生下行事件未隔离 owner：已携带并校验 owner。
- 原生呈现 await 期间的 end 无法取消随后才启动的 answer：已同步记录取消意图并在 accept 前检查。
- 旧 DELETE/晚到 PUT 干扰新 owner：已精确 owner 比较与有限期退休墓碑。


## 补充复审：固定 Docker 私网 admin origin

复审日期：2026-09-08。范围为 gateway.py、compose.yaml、README 及上游行为测试的最小部署适配；检查的是 78a234fd 之后当前工作树中的 private-admin-origin 改动。现网 nginx 拒绝 /_synapse/admin/ 与既有 starchat_default 网络事实由部署操作者/root 提供，本审核者未重新连接生产验证。

结论：该最小适配的领域与配置安全复审通过，无新增阻塞。允许在既有受信 Docker 私网上使用固定 http://synapse:8008 读取接收者账户/设备资格；不允许据此开放公网 admin 路径或扩大为任意上游。

- production_app 强制要求 MATRIX_ADMIN_URL。输入归一化后仅接受固定 http://synapse:8008；实际 admin client base_url 更直接固定为该常量，不采用可变路径、用户信息、查询参数、端口或其他主机。
- admin_client 与公开 Matrix client 独立，均设置 follow_redirects=False、trust_env=False 和八秒超时。只有 eligible 的两个固定只读 admin GET 使用管理员凭据。用户 whoami 与加密房成员检查仍由 HTTPS Matrix client 携带用户 Bearer 完成。
- URL 中的用户/设备标识经过编码；admin 错误与 302 均失败关闭，不跟随跳转、不向响应暴露上游内容。管理员凭据不进入公开 Matrix/nginx 地址、APNs、响应或 SQLite。
- Compose 显式加入操作者指定的外部 MATRIX_DOCKER_NETWORK，部署选择必须为已核实的 starchat_default。主机发布仍仅 127.0.0.1:8099；此变更不修改既有 Synapse 或 nginx 的 admin deny。
- HTTP admin 链路不提供传输层加密；本批准明确依赖同一受信 Docker 主机/网络的既有边界。管理员 token 本身仍为高权限凭据，代码限定 GET 并不等于 Synapse 赋予只读权限。README 已如实记录，不将该配置描述成低权限 token 或公网安全接口。
- 该改动仅改变资格查询的传输路由；不扩大 E2EE、Keychain、业务身份或媒体授权范围，前述 ADR 0011 领域批准保持有效。

验证：本审核者独立运行 tests/test_upstreams.py：15 passed in 13.15s，退出码 0。覆盖公共/私网凭据分离、八种不安全 admin URL 拒绝及私网 302 不跟随。已读取实现代理保存的 gateway-private-admin-green.txt：52 passed in 8.87s；此全量结果明确归属于实现代理，不冒充独立重跑。部署网络解析、既有 nginx deny 和实际 Synapse 资格接口仍需 root 部署烟测核实。
