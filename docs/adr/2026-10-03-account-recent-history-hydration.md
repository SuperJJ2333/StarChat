# ADR：账号范围内的最近72小时密文历史补齐

状态：用户既有ADR自主授权下的方案，已按独立D1–D5/Q1–Q4修订并通过领域/规格、质量/安全有序复审；实现仍需独立审查。关联规格../superpowers/specs/2026-10-03-search-camera-history-design.md、计划../superpowers/plans/2026-10-03-search-camera-history.md Task3；审查证据见docs/verification/artifacts/2026-10-03/search-camera-history/recent-history-design-review.md §5。首次创建在线备份或补齐SAS流程未包含在本决策的已审范围，不得据此创建替代备份。

## 已观测问题

当前_syncActiveClient仅执行active.sync和uploadInboundGroupSessions，未覆盖所有已加入群聊/私聊最近72小时分页；main在bootstrap之后的后台恢复只调用已有store recovery及syncIfActive。已有用户自有密钥恢复途径不能被替代。SDK Room.requestHistory在resp.end=null且chunk非空时loadFn直接返回，可能漏末页，须行为复现后按任务归属修正，不把此观察当已修复。

## 决策

新增窄的近期历史协调器，通过现有Matrix公共能力读取/持久化密文事件和已授权本机解密。owner是捕获的Client实例+账号homeserver/userId+登录generation，不是全局当前房间。成功授权初次sync后启动，不等待其完成才显示登录成功；同一owner多次sync只唤醒未完成/失败任务，不从头重新扫描。当前加入房间（包括群聊、私聊与逻辑会话来源房间）均纳入；新加入房间可排队。固定本次登录now-72h cutoff；跨重启复用同账号数据库分页位置与已落盘记录，防止重复扫描历史。在安全存储中不保存新的明文消息/密钥/账号可外泄数据；覆盖标记只能在真正越过边界或历史取尽后提交。

每个网络页固定80事件，最多2个并行房间；每个调度片最多32页或2秒处理，然后yield并轮换房间，再继续未完成队列，不能用这限制永久截断三天历史。单网络请求有8秒超时；网络/服务器临时失败以有界退避重新唤醒，不热循环，长期离线不称完成。禁止创建长期保留完整三天events的Timeline/list；只保留当前页、游标、时间覆盖和有限工作队列，事件落现有账号加密库，页面窗口/媒体内存预算不扩张。进入当前会话与主动定位优先于后台补齐；同房间并发分页必须串行/去重且不能互相覆盖cursor。非消息state页仍依据所有事件timestamp/token进展处理，空但有变化token不能误认取尽；重复token/无法越界记未完成，可重试。

所有外部await前后核对owner，真正suspend/logout/selectAccount/clearLocalChatData之前同步cancel/revoke，迟到请求只允许释放旧owner资源，不能换成新client写入或调度新账号。SDK网络和commit使用捕获的旧client；提交前再检查，生命周期tracked operations保护数据库关闭，不能把客户端取消当作网络已取消。临时失败不撤销账号或本地聊天库。任何状态/日志仅匿名聚合计数/错误阶段，禁存真实消息、token、room keys/recovery keys。

## 密钥与解密

不改变Megolm/设备验证/备份信任规则，不制造新备份覆盖旧备份。使用已解锁的当前账号Matrix备份，按新页缺失session使用SDK现有key-manager恢复/可信设备共享，避免每次sync调用全账号loadAllKeys。用户主动现有恢复成功后唤醒未解密页/本地记录重试；onRoomKey/SDK解密事件可刷新本机投影，受账号generation限制。已有restoreAllInboundSessions流程如需增加重试钩子，仍只能在该恢复操作和账号有效后执行。

账号无备份解锁秘密或无对应session时，保存密文并保留needsRecoveryKey/missingKey状态；三天密文覆盖与可解密覆盖分开，不显示为恢复完成，不返回假正文或让业务服务器持有密钥。跨设备正确解密依赖用户已有有效备份或已验证旧设备；所有恢复材料丢失则不可解密，此约束不可通过代码绕过。本机已清空/隐藏记录在后台下载后仍隐藏，撤回和闪照规则保持，不设置已读收据。

## 可验证证据与回退

真实RED/GREEN：生产SDK路径初次sync后至少两房间跨三天；明密混合及备份session恢复后显示；同设备A→B的持有网络/keys结果隔离；旧页最终end=null仍落盘；高量分页累计覆盖而内存≤当前页/有界窗口；断网/无进展及cancel无spin。独立领域/规格审查在安全审查之前；不将测试stub当真机新设备密钥验收。

无需服务端契约、加密算法、业务DB或破坏迁移。回退可停新增协调器，既有同步/密文库/密钥仍可使用；不清数据、不强制新设备身份、不回退已经上线的Getui v1服务。本方案需具体实现接口/数值在报告冻结并按review修正，受保护的信任边界改变需更新ADR重新审查。

## 独立审查修订：D1–D5 / Q1–Q4（本节收窄前述契约）

1. 恢复入口必须实际可达：认证后设置→聊天记录恢复，并在近期密文缺密钥时显示可点恢复入口。复用并修正MatrixSecurityPage/MatrixRecoveryService，恢复键只在本机临时输入，完成/撤销/dispose清空输入；不开启替代备份的createKey修复按钮。此任务交付真实用户恢复密钥途径，现有SAS缺对比值/发起流程，不宣传旧设备恢复已经可用，不将手动setVerified绕过作为替代。状态区分下载中/密文下载完成但需密钥/恢复中/部分可解密/备份不可用/可重试失败/已撤销，导入完成不等于全部历史已恢复。

2. 后台绝不直接调用Room.requestHistory或Client.handleSync伪造同步。SDK新增独立游标页面导入公共接口，getRoomEvents原始网络无存储副作用；捕获Client和owner后在现有账号加密DB事务批量存原始密文事件及独立checkpoint CAS。事件IDs去重/已有redaction保持，历史state不覆盖当前state，live Room.prev_batch/global sync token/当前成员/加密状态/预览/未读和高亮计数不改。允许仅用本机database私有namespace存checkpoint，禁止client.setAccountData上传；checkpoint是DB generation+格式version+room+windowStart/End+cursor+revision+覆盖区间/待重试，非永远complete bool。有限实时sync导致fragment删除时失效/协调已有coverage；下一次登录要从新head桥接离线间隔，已完成旧窗口不跳过新空隙。Task1 context的稀疏事件不证明连续72h覆盖。

3. 每页都落盘，包括end=null的非空末页/仅state/空但token变化；timeout不能当exhausted。相同或循环token有界stalled重试。固定cutoff与捕获head，先用timestamp_to_event获取边界eventId作为服务端顺序锚，再从新head按独立游标连续走到该锚或确实耗尽；不能仅凭某页最小origin_server_ts越界称覆盖，out-of-order timestamp须测试。不支持边界定位且无法证明连续覆盖时保留incomplete，可继续遍历到耗尽或明确可重试失败，不能伪造完成。任务拥有SDK末页丢弃的行为RED和最小修复。

4. 真正backupKeyMatchesCurrentVersion需检查当前version/algorithm和用户缓存私钥推导公钥对备份authData的匹配，复用固定SDK crypto，不以isCached作为匹配。导入返回实际可用/部分/无备份/需要密钥/不匹配/撤销结果，不吞零导入当成功。自动只处理已有可用备份缺失session，去重(room,session,backupVersion)，工作项仅短ID且有界，Ciphertext落盘等待bounded replay，避免SDK maybeAutoRequest失败后永久不重试。只显式恢复可loadAllKeys，不每次sync全库拉keys。监听实际room.onSessionKeyReceived，在当前owner内重试落盘近期密文并刷新本机消息/搜索；导入/共享密钥完成仍保留缺失session状态。

5. 页导入不向Client._eventsPendingDecryption塞全三天Event对象；逐页解密/索引投影或只存密文，缺session从DB有界重读。固定最多2页body、每页80、当前已有有界UI窗口；数量证明只限新增body working-set，不能声称整个SDK O(1)。批量导入避免MatrixSdkDatabase.storeEventUpdate每条都全room IDs读取；新实现高量profile记录body数量、SDK索引实际保留/时间，不扩大既有消息/GIF缓存预算。

6. 完整secure-store read→unlock→match→import→replay属于单个不可变owner，owner绑定captured Client/homeserver/userId/DBgeneration/授权generation，不能每一步重新_withClient绑定当前账号。所有await后核对；恢复状态和输入框不跨账号。suspend/logout/selectAccount/clear入口即同步取消新的协调器和timer/subscriptions，排队入场不能等待旧owner继续。

7. 网络8秒仅响应deadline，raw fetch late丢弃不能开始write；真实数据库/key写Future完整登记和drain。5秒lifecycle drain不能直接dispose仍写的DB：有写未settled应报告关闭失败并保留旧资源直到安全结束，而非继续关库/换client。不持DB事务等待网络，fire-and-forget key writes禁止逃出owner accounting。自动key请求有界，不把timeoutwrapper当真正写完成。

8. 调度：80event/页、2房间网络并发、每(owner,room)一次ingest，32committed pages或2秒yield（哪个先）；foreground房间操作优先下一后台页。瞬时失败退避1/2/4/8/16/32/60秒，允许jitter，未完成继续；无进展/离线不spin、不清tokens/DB，不把slice cap当coverage cap。所有checkpoint/消息密文仅账号SQLCipher，不记录roomId/token/正文/密钥。实际复现涵盖多slice、高量、crash replay、并发foreground/limited sync、末页/state/乱序/循环页、key locked/mismatch/late和A→B held callbacks所有边界。

建议接口名称/签名在recent-history-design-review.md §3；具体实现可作最小等价接口，但必须在报告绑定并由独立最终审查确认。上述不是新增服务器信任或财务改变。
