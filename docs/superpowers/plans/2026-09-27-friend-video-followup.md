# 好友搜索与视频反馈实施计划

> For agentic workers: 使用独立owner，先red/green，规格审查先于质量安全审查。不得同时写同一文件。

Goal：实现用户五项反馈、保留最新全链路性能诊断，交付可复验Debug及明确iOS原因边界。

Architecture：认证POST好友发现→identity公开资料服务，旧GET不开放手机；严格完整contact与username最多末尾两位不同/省略，原片预览与发送转码独立，既有scope/trace不退化。

Tech Stack：Flutter3.44.9/Dart3.12.2、Python3.12/FastAPI/SQLAlchemy/PG16、现有HTML registry/token。

用户本轮指令与[设计](../specs/2026-09-27-friend-video-followup-design.md)为执行依据。隔离工作树friend-video-followup，branch codex/friend-video-followup；360原目录源输入逐SHA复制，保留前轮账号与regional增量；最新c936分类器3文件有独立manifest。

## A Backend owner inspect_profile_identity

Files：identity/profile.py、api/friendship.py、必要friendship/service.py、migrations新0090好友检索非唯一索引；test_user_search.py及必要API/phone/PG测试。不得修改根BusinessApiClient、OpenAPI、main.py或生产接收文件。

- [ ] 写失败：邮箱前缀不得命中、完整邮箱含320长度、手机完整/partial/privacy/blocked/配额、用户名长度差0..2/大小写/转义/旧合法号。
- [ ] 实现identity公开search及共同phone quota，候选范围内设备活跃排序。扩展q上限与文档，保持DTO无完整contact字段。
- [ ] 必要非破坏性索引迁移+online/offline/invalid-index恢复说明；先green，再PG16合成EXPLAIN/并发与独立领域安全审查。

## B Video owner inspect_live_account_api

Files：device_gallery_source.dart、image_picker_page.dart、gallery_video_preview.dart、wechat_video_message.dart及仅相关video lifecycle/picker/send测试。

- [ ] 写失败：原片可播但编码两档失败仍可预览；原片解码不支持→原策略fallback；撤销/迟到/重试不删asset/不泄漏输出；视频加载无顶部胶囊、仍有inline反馈。
- [ ] 原片先播、必要时才transcode预览；发送路径完全保留规范。用既有public trace接口记录必要阶段/闭合错误，不记录路径/原生异常文本/媒体内容。
- [ ] 聚焦green/analyze；自有合成H264/AAC等短样本模拟器验证，有缺口明确标记，不取用户媒体。

## C Mobile contacts owner（待调查owner转交）

Files：contacts_page.dart、scan_qr_page.dart、add_friend_search_test.dart及扫码exact测试。不改BusinessApiClient由root接线。

- [ ] 三渠道placeholder/help、请求revision失效red。
- [ ] 保留公开gateway入口/profile关系/身份cache，新增输入不沿用旧搜索结果造成误选；二维码无exact不得fallback第一人。
- [ ] 新输入/清空/提交/过期成功失败/三渠道回归green、token及HTML公开文案提供root。

## D Parent root username/UI/diagnostic/docs/integration

Files：username_change_page.dart及其测试；必要BusinessApiClient contract；frontend contacts/username/media catalog/components/styles/tests、registry、OpenAPI、设计/ADR/任务/报告。

- [ ] 写UI本地blur缺失red，HTML先按既有token提供分层说明/反馈；focus loss即时规范校验及same-draft去重/异步revision保护。
- [ ] 接线backend公开contracts；性能源最新c936 patch与6f现有hooks输入SHA检查，新增/相邻classifier回归。
- [ ] iOS只读调查记入独立小节；用户新信息到达后继续因果分类，不擅改受保护恢复边界。
- [ ] 聚焦测试→规格/安全独立review→最终冻结；Flutter全量/analyze、frontend/UI、API/worker/verify适用门禁及OpenAPI/PG16。
- [ ] 原目录360输入漂移保护，保留并行network receiver/diagnostic变更；具体候选及迁移准备后遵守独立生产授权。
- [ ] 实际模拟器版本/ABI重核，选未占用build；源码→标准DEX/resources/manifest重建→固定签名→原生ABI校验→保留数据-r安装及实际启动/样本复验。
- [ ] 写阶段计时/源hash/索引与证据，区分源码/发布/安装/真机/真实OTP。
