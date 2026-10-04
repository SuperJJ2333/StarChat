# 2199 搜索媒体网格端到端遗漏修复

沿已批准历史消息/旧媒体修复目标与自主实施授权，补齐实际RoomPage搜索入口；不扩展产品行为、不清数据、不重置密钥。基线main ad728e6e，模拟器实际0.4.30+2199/UID10090/首次安装保持。旧测试通过仅证明SDK媒体解析与安装smoke，用户反馈证明真实页面仍失败，H2重新打开。

已确认源码链：LocalRoomHistorySearch提供窗口外持久搜索结果；RoomPage.currentSearchMessage只controller.findMessage；mediaThumbnailBuilder在current==null时返回nullfuture而不进入已修SDK loader；onOpenMedia同样return。复用公开单事件lookup接口和已验证sourceRoomId提示，不用拼搜索索引正文构造信任事件，不扩大live窗口/72h，不直接跨模块写数据库。

1. 真实RoomPage→查找聊天记录→图片与视频widget入口写RED：旧本机搜索结果在live窗口外，列表项存在但原生小PNG缩略图未显示且实际loader没被调用；今天媒体对照。图片、视频、直接打开旧结果、跨关联房间source提示、隐藏/撤回/闪照/账号撤销/迟到结果负例。
2. 最小修复UI前置解析：可见性检查→只从已记录合法room/event source提示→已有公共单事件lookup→再检查可见性/搜索生命周期/当前owner→现有image/poster loader。并发重复读取有界去重，不从build每次无限新请求。无完整视频下载作封面；临时缺钥/失败允许后续重试。
3. 保留房间时间线位置和当前窗口；分页网格处理实际viewport可见项，视频/图片查看器用同一已验证结果。测试必须经过实际RoomPage wiring，不能只helper/API假通过。
4. 有序独立spec/domain后quality/security审查。相关搜索/媒体/隐藏/窗口/连续性测试、analyze、最终候选共享全量；verify环境预检如实记录。平台检查按改变输入复用规则，密钥加载源码不改时旧iOS连续性证据明确关联相同输入，必要完整native编译/运行按最终scope执行。
5. 线上/CI/设备只读核号后配对冻结下一debug号，源码→Apktool2.12.1→zipalign36/P16→原75b31签名→独立验包→install-r保留数据。实际模拟器旧媒体网格场景验收或明确实测限制；不以进程smoke替代缩略图显示。保留1372primaryWIP，双审后main集成与远端读回。无本轮正式移动/IPA发布授权。

root拥有计划/任务/证据/版本/打包/交付；单一实现actor独占RoomPage及必要helper/tests与Flutter；独立reviewer只读。SDD fresh actor受会话threadlimit影响，复用现有实现actor并复用独立whole_candidate_review审查，无文件并发编辑。
