# 正式构建合入会话修复及好友链路修复

用户2026-09-07授权执行：合入相册与全部会话修复，保留已发布钱包改动；修复删除好友、新好友会话无法收发。
1. Root owns正式目录补丁集成/共享登记/构建验证；以4afbc6c→9f3cef8补丁按文件合入，重叠registry/ledger按key合并，不改动已有wallet/iOS源文件，记录之前hash。
2. 用户澄清：删除 API 已成功，但需重启才能刷新。删除任务 owns contacts_page.dart、profile_repository.dart 及对应测试；API成功后立即更新共享联系人及持久缓存、通知界面，失败或取消不删缓存，防止在途旧读覆盖删除。保持业务删除接口不变，不代用户删除真实好友。
3. 私聊任务 owns DirectChatService、Matrix DM/invite接线及测试；分析新好友房间选择、加入、加密状态、发送与收件人同步，不能取消E2EE或绕过权限。RoomPage若需修改先声明。
4. 各任务规格审查后质量审查，root整合测试、analyze、UI契约及verify；正式源含wallet原有功能且相册动态日期条件存在。发布包必须正式签名与递增build，最后核对不可变APK及更新设置，未经测试不能直接用debug包替换正式包。

Root additionally owns app_home.dart 的好友消息入口及 canonical room 加入补丁，保留该文件现有 iOS 推送实现。缓存命中直接打开；新好友缺少共享资料时向业务 API 核实再打开；不得凭旧详情页面自行恢复删除状态。
