# 历史消息、旧媒体与iOS连续性回归修复

状态：沿原任务用户自主实施/ADR决策授权继续既有设计的回归修复；本轮用户确认Android模拟器2198及真机2196出现问题，L04/L07为预防要求。既有托管ADR和历史覆盖设计继续约束实施，不扩展密钥托管契约、不重置本机密钥或历史库。

基线main3b9d7c24，复用隔离工作树search-camera-history-20261003，新分支codex/history-anchor-media-ios-20261004；主目录1372无关trackedWIP及既有索引记录保留。root负责台账、整批门禁、平台交付与整合；各实施任务依次独占源码与Flutter工具。

## 目标与设计

H1：搜索五天前乃至更早本机/服务器可访问消息，可真正定位可见气泡；本地密文按原SDK加密校验解密，不把密文误判为不存在。保留撤回、隐藏、账号/房间绑定、取消/迟到结果和原生分页边界。

H2：图片和视频历史列表的窗口外事件，从本机库优先、必要时单事件网络获取和本机解密后按需下载缩略图/正文；当前1000事件工作集不是媒体存在性的边界。缓存身份必须来自同账号/房间的已解析可信事件，不让缓存替代权限/哈希/解密校验。不把全部历史或附件载入内存，不改变72h后台补齐范围。

I1：真实SDK初始化中，设备身份采纳与恢复写入排空失败不能留下内存、durableclient和账号绑定不一致的状态，导致后续登录/账号选择永久L04/L07。恢复网络/迁入失败保持后台重试；真实凭据/存储损坏仍经过原校验。保留原Olm身份和已有库/keychain；加入已保留账户、服务端device轮换、持有旧owner写入、deadline/释放/重试场景。先证明具体失败，再选最小修复。

## Task1 历史事件与媒体按需解析

拥有lib/features/matrix/matrix_e2ee_client.dart、必要logical_conversation_timeline.dart与third_party/matrix/lib/src/room.dart，以及相应历史/媒体测试。不得共写其他任务文件。

- [ ] 原有测试基线及本地密文锚/窗口外媒体RED，确认失败原因；纯明文mock不替代加密库恢复。
- [ ] 最小公共解析路径：本机/网络对称解密、可见性/源房间绑定、取消/owner撤销、真实写入生命周期、有限缓存和并发单事件读取；不通过扩大窗口/全量扫描隐藏问题。
- [ ] GREEN相邻测试/analyze；实际SQLite/SQLCipher与Olm/Megolm旧事件5天、图片/视频缩略图及正文hash门禁，合法隐藏/错误room/sender/session/key negative。
- [ ] 独立规格/领域审查后质量/安全审查；明确源码commit与日志hash并释放所有权。

## Task2 iOS L04/L07风险防护

Task1释放后fresh implementer独占matrix_e2ee_client.dart、必要SDK client.dart及core/session_store.dart、对应recovery_vault_sdk/matrix_client_factory/ios continuity测试。

- [ ] 真实SDK保留账户+旧owner held write+device轮换RED，确认内存/数据库/绑定分裂及重试条件。
- [ ] 最小身份采纳失败恢复/正确持久绑定或等价原子流程，重试不依赖重启/清数据；保留真实排空及owner隔离，不以timeout视作settled。
- [ ] 首次登录、同设备token续期、设备轮换、迁入失败/暂时网络错误、同账号重登、切号、原库/Olm指纹保留及损坏/异账号拒绝GREEN；iOS storage/keychain原生相关门禁。
- [ ] 独立规格/领域→质量/安全审查，冻结commit/日志hash。

## Task3 整批验证与交付

- [ ] 完整Flutter/analyze、相关Python/原生/契约检查；verify.ps1环境预检，未改local.env前置限制如实记载。
- [ ] 检查源码/版本与线上事实后冻结下一debug版本，常规重建/对齐/稳定签名验包；保留模拟器数据安装并至少120s smoke。
- [ ] 同源iOS完整native编译及iOS18/iOS26、必要新连续性集成用例；真机验收与模拟器证据分开。
- [ ] 保留WIP整合推送main，更新台账/索引/公开证据；本轮没有新增正式移动发布授权，沿原debug交付范围，生产服务变更只有证实需要时按原保护门禁执行。

Ruling：本轮沿已批准恢复/搜索行为做错误路径修复，原用户授权自主ADR/实施决策持续有效，无需再次审批同一目标。若失败测试揭示服务契约/加密边界需变化，先更新对应ADR并完成保护双审，不先扩大实现。
