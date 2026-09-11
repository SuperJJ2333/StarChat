# 朋友圈与即时通讯 Mi 6 debug 修复实施计划

授权：本轮用户完整需求即范围批准；只交付 Mi 6 debug，不生产发布。用户明确“无需你自己测试”，因此不执行自动化测试或真机交互测试；保留源码审查、编译、APK签名/内容及安装身份检查，功能验收交用户，不把未测说成通过。

基线：8ec6782e；独立工作树 codex/moments-im-mi6-20260910。采用 systematic-debugging 根因先行与 subagent-driven-development 分模块实施、规格后质量审查。UI 按 ui-demo-delivery 同步 HTML/registry。

- [x] A 朋友圈入口：moment_person_navigation 当前构造 ContactProfilePage 丢失消息/通话回调，接通已有统一联系人动作公共入口；检查双方ID规范私聊协调器的所有入口和并发路径，禁止异常回退新建。自己评论仅 longPress 打开菜单，短按不弹菜单，菜单单实例，保留他人回复。负责人 profile agent；拥有 features/moments、联系人必要修改、app_home（须通知root），不得改 room_page。
- [x] B 撤回：追踪 Matrix redaction -> 持久化 -> timeline -> 气泡菜单；本人3分钟内可撤回，服务端事件为权威，撤回占位不因新消息/同步重建消失；保留多端/重启读回。负责人 recall agent；拥有 timeline、message_interaction、第三方Matrix相关源码；room_page 必须提供补丁给root，matrix_e2ee_client 修改需与media协调。
- [x] C 内容缓存：审计现有 SHA256 内容地址缓存、可信哈希传递、发送/接收/转发/收藏和图像 provider；相同字节共享磁盘实体、内存读和 in-flight，清理后可重建。明文哈希只能在 E2EE 消息内部传递，不改变加密边界。负责人 media agent；拥有缓存/media发送/提供器，shared SDK 文件先报具体区段；room_page 提供补丁给root。
- [x] D 图片查看与编辑：root 负责 room_page、ui/chat/encrypted_media_view、新图片编辑组件、frontend、registry。当前房间图片序列分页浏览；统一编辑文档实现画笔、emoji、文字、裁剪、马赛克、undo/redo；栅格化结果由现有加密发送/收藏/相册存储入口处理，取消不改原图。工具及完成菜单按用户指定位置。
- [x] E 集成审查：逐条记录根因/复现/修改/未测回归清单；先规格符合性再质量/安全审查。构建ARM64 debug、Apktool2.12.1重建、zipalign、固定签名，ADB保留数据覆盖安装到 cbd0156b；不卸载、不清数据、不运行交互测试。

方案：复用既有规范私聊协调、Matrix redaction、内容地址缓存和媒体业务入口，补缺失链路；不新建第二套好友页、撤回存储或媒体缓存。

