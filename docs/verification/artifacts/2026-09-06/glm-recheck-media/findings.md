# 7b3177b 媒体独立复审

只读生产代码；HEAD 确认 7b3177b。发现：

- P1 / R7 尚未修复实际气泡：room_page.dart:2058 定义图片判断，2136-2144 图片专用分支仍构造 EncryptedImageMessage；2192 只有 else 才进入 _messageContent。因此 1881 的 ContainImageBubble 替换被实际图片分支绕过。encrypted_media_view.dart:124-129 仍固定尺寸 BoxFit.cover。
- P1 / 视频会话缓存未接入：rg 全 lib 对 VideoPosterSessionCache、VideoPosterCell、AnimatedImageCell、GifAutoPlaySetting 只有类定义，无业务实例。room_page.dart:201 使用页面所有的 MediaMemoryCache，943-950 从该缓存加载海报；新会话磁盘后端也没有实现。
- P1 / GIF 路径未完成：room_page.dart:1003-1015 所有非视频发送附件生成缩略图；media_thumbnail.dart:28-38 强制 JPEG；room_page.dart:2147-2151 显示该缩略图，encrypted_media_view.dart:112-115 查看器也先显示相同 previewBytes。新 GIF 组件即便接入，video_gif_cells.dart:218 无条件 Image.memory，shouldAnimate 仅控制播放按钮；324-326 可见性实现直接返回 child，永不通知离屏。
- P2 / R11 clearAll 仍遗漏磁盘条目：video_poster_session_cache.dart:210-218 只枚举 _memory，LRU 淘汰或 clearMemory 后磁盘条目不可枚举，清理后继续命中旧条目。cache_repro.dart 场景一已经复现：a,b 加载、内存只容一条、clearAll 后 disk keys (a)。
- P2 / R11 在途磁盘写入仍复活：video_poster_session_cache.dart:119-127 只在 diskWrite 前检查 generation。等待写入中 clearAll/evict 删除文件后，写入仍可完成；结果 stale=false。cache_repro.dart 场景二已复现：clearAll during diskWrite: disk keys (x), stale=false。
- R13 局部修复成立：contain_image_bubble.dart:125-131 现在比较字节和 maxWidth/maxHeight 并重新计算，但正常聊天图仍不会使用此组件。

复现：`dart run docs/verification/artifacts/2026-09-06/glm-recheck-media/cache_repro.dart`。输出见 cache_repro_output.txt。此脚本仅验证独立缓存逻辑，无网络、无生产数据操作。
