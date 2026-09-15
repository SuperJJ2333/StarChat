# 2026-09-15 新好友资料页“发消息”报错修复与 Mi 6 Debug 2118 交付

## 现象

新增好友 zhsb 的好友资料页点“发消息”报“无法打开加密会话”；从群聊或朋友圈进入
同一好友资料页点“发消息”正常。入口数据差异 + 时序差异叠加导致。

## 根因

不同入口的 `ContactDetails` 来源不同：

- 群聊成员/朋友圈入口：contact 从**房间成员列表**（Matrix 实时状态）构造，
  `matrixUserId` 一定有效；
- 通讯录/新的朋友入口：contact 来自本地好友缓存（接受好友时的快照）。
  新好友刚接受时本地缓存可能**尚未写入 matrix 绑定**（`matrixUserId` 为空字符串），
  之后除非触发刷新否则保持为空。

空 `matrixUserId` 传入 `directChats.open('')` → 查不到/建不出私聊 →
`_openManagedRoom` 内 `openRoomLease` 失败 → 统一渲染为“无法打开加密会话”。
DB 侧已核实 zhsb（gjjyrdfjk）在 users 表的 `matrix_user_id` 为
`@gjjyrdfjk:matrix.localhost`（数据正常），`friends` API 亦按 users 表回填——
问题只在客户端本地缓存时序。

## 修复（commit 前后两笔，源码 71f4b823+）

`AppHome._openMessage` 防御：

1. `matrixUserId` 为空白时，先按业务 `userId` 从 identityCache 反查（contactsByUserId）；
2. 仍缺失则强制刷新好友目录（refreshContacts）后重取；
3. 仍为空才抛“该好友不可用”（有明确文案+重试按钮），不再以空 id 闯 DM 创建流程。

## 自测与交付

- Flutter 全量 **2672 通过**（含探针构建真机复测进入路径）；analyze 零问题。
- 0.3.91-debug/2118 固定流程（Apktool 2.12.1 + zipalign + 固定证书 `75b31c66…`），
  aapt 验证 `com.liuhetong.mobile` 2118 / arm64。
- 最终 SHA256：`D3783ACD729149D73DC377307340FABE4C7C2EA208B0227BB144E483ECC2F32D`
- Mi 6（cbd0156b）root 覆盖安装（数据保留），读回 2118，已启动。
- 未发布：仅 Mi 6 交付；服务器/更新弹窗/iOS 不变。源码已推送（`71f4b823`）。
