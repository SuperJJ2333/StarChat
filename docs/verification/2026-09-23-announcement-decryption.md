# 公告解密恢复专项

候选：`.worktrees/debug-feedback-2164`，基线 e8bf1440；批准计划 `docs/superpowers/plans/2026-09-23-debug-feedback.md`。

## 范围与根因

SDK `decryptRoomEventSync` 在密钥缺失时返回 type=m.room.encrypted、msgtype=m.bad.encrypted，同时 originalSource 仍为 encrypted。公告 load 原来只校验 originalSource 随即按文档解析，产生 FormatException 并显示“公告格式异常，暂无法显示”。公告 changes 只关注 room join 同步，未关注 onSessionKeyReceived；图片的 failed Future 在密钥恢复后也未刷新。

仅修复已复现路径：未解密事件转可恢复状态“公告正在解密，点击重试”，加入房间密钥恢复监听，失败图片恢复时重新走既有 boundedChatImageProvider、loadMediaWithCache 与本地解密下载。合法 blocks、旧 topic 与非法文档处理保留，未引入 HTML 解析或远端图片 URL 接受。不修改 Matrix 权限、加密协议、业务 API、钱包。

## 红绿与证据

Windows PowerShell 7，C:/src/flutter；依赖由root预检，使用 --no-pub。

- 红：`flutter test --no-pub test/features/matrix/group_announcement_member_test.dart --plain-name 'pending document key'`，exit 1，明确找到不应出现的“公告格式异常，暂无法显示”。
- 红：同文件 `--plain-name 'image key recovery'`，exit 1，密钥恢复后期望1个Image实际0。
- 绿：`flutter test --no-pub test/features/matrix/group_announcement_test.dart test/features/matrix/group_announcement_member_test.dart test/features/matrix/group_announcement_draft_banner_test.dart`，exit 0，38通过。
- `flutter analyze --no-pub` 指定2生产文件与上述3测试文件，exit 0，No issues found。
- HTML红：`node --test frontend/tests/announcement-recovery.test.mjs`，exit 1，Unknown screen。
- HTML绿：`node --test frontend/tests/announcement-recovery.test.mjs frontend/tests/screen-registry.test.mjs`，exit 0，5通过。
- 原测试继续覆盖成员权限、明文引用拒绝、旧topic、空引用不复活、图文顺序、草稿取消不发布、图片预算和加密附件envelope。发布测试补充local image→图片event→文档→opaque state→SDK已解密历史重新打开，不保留localBytes。这是服务层SDK边界fixture回归，不是真实两机E2EE测试。

## UI与审查

Figma 已退役：本次变更仅更新 HTML demo（frontend/index.html?screen=chat-announcement-mixed）。

`frontend/src/screens/messaging.js`、`frontend/src/catalog/screens.js`：mixed/decrypting/malformed；复用现有space-lg、navigation与本地图片素材；registry由root统一更新。2026-09-23 20:22 HKT通过in-app browser检查8156预览：图文顺序、contain图片和16px留白正常；等待解密按钮点击后显示图文；malformed保持独立错误。共享UI契约、全量门禁、最终构建由root候选统一执行。

规格自审：通讯文档与图片仍仅端侧解密、房间成员授权不弱化；历史文档格式兼容保留。安全自审：未接受任意HTML/URL、未上传解密内容、未改变密钥请求策略；订阅在widget/service切换或销毁时取消，图片已成功时不因无关sync重新加载。

已复现的错误分类与恢复路径修好；用户原图片公告是否另有格式/密钥永久不可恢复问题仍需2164真机复验，不能据本专项宣称所有图片公告问题已消失。

时间：起点与主动/工具分解未知，收尾记录 2026-09-23 20:23:34 +08:00；下一步root运行最终门禁、构建安装与原群图片公告真机复验。

## 文件SHA256
- apps/mobile_flutter/lib/features/matrix/group_announcement_service.dart: 372E423B56CC0E3EF5212ED15E3C5171BD564EB8BD19F1C2D8240DEDF5910843
- apps/mobile_flutter/lib/features/matrix/group_announcement_page.dart: 7F96F25461F5131DE1BD8ECDFE6BCF5E729EE22277DAFAED29BE861BF65782F4
- apps/mobile_flutter/test/features/matrix/group_announcement_test.dart: 67E9E9D915BB3B17793F9EA5C5B4E72D1A81E0001D2F48381818685F63B21FF2
- apps/mobile_flutter/test/features/matrix/group_announcement_member_test.dart: 08B317236AA1E91AAD17C7B4EC743F26722F636C4AB3002B839674571BBEAF7A
- apps/mobile_flutter/test/features/matrix/group_announcement_draft_banner_test.dart: F65CC5C3BF6DF4047BAC5FF397FE859FDB163640D50D44F339C91F76F341C288
- frontend/src/screens/messaging.js: E74DE5BB7F32751CC621D2363E5A86EE2CEB8A2F4E092002333445BFADC6E00D
- frontend/src/catalog/screens.js: D5807E2F338A40606A3D59E147BB78F9ADDA29D7F6BED271FB264C7228F4A6D8
- frontend/tests/announcement-recovery.test.mjs: D17087C763AB048BBFD3F127E692A8578EAB9F12F4E0387F26C855F9CB15ACF0
- apps/mobile_flutter/pubspec.lock: 484A85F5521A3FCCE8C47BF8300C705A9C7F04C28ED82CBFAD85370D9DB05051