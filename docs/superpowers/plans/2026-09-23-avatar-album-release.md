# 头像、统一相册、公告恢复与 Android 发布计划

用户 2026-09-23 五项要求及头像仅静态图片的澄清为本计划授权。只发布 Android 安装包和 Android 更新弹窗，不发布 iOS；朋友圈视频所必需的兼容服务端改动独立验收。

架构：复用 UserAvatar/AvatarCache、ImagePickerPage、现有图片裁剪编辑器及媒体缓存；不创建第二套相册/缓存。Matrix 公告保持端到端加密，不用明文旁路恢复。朋友圈业务媒体保留鉴权、所有权与可见性检查。

## 执行与验收

- [x] A1：追踪本人头像预热、显示、刷新和失效的缓存身份。失败测试证明重复加载；统一身份后验证跨页面复用、换头像更新和账号隔离。文件：profile、ProfileRepository、UserAvatar/AvatarCache 及对应测试。
- [x] A2：头像选择复用 ImagePickerPage，单选静态图片，隐藏视频和 GIF。复用 Flutter 编辑器的正方形裁剪、安全区退出及确认；测试取消、完成、错误、上传后返回页更新。iOS 不可用真机则明确未验，不用 Android 测试替代。
- [x] A3：沿 SDK getEventById/decryptRoomEvent/requestKey 复现公告缺密钥，修正历史事件恢复而不是仅改提示。验证加密来源、群成员、失败重试、事件/密钥订阅与退出取消。
- [x] A4：朋友圈入口统一为“相册”。上传前与服务器均限制单个视频 20 MiB；媒体类型、所有权、可见范围、重试、草稿及发布回显有专项测试。视频展示复用媒体缓存、既有播放器；旧 iOS 图片字段维持兼容。
- [ ] A5：先审查各分支及未提交差异，归档未合入内容；整合后只保留 main 分支，不删除尚未保存工作。执行规格、质量安全审查和相关完整门禁，保留失败和跳过证据。
- [ ] A6：冻结版本/源码，源码构建 Android ARM64 正式包，经 Apktool 重建、固定签名与工件门禁。按轻量发布流程上传不可变 APK，仅发布 Android 元数据/弹窗。通过 Git 正常推送 main；不强推。

HTML demo 同步现有头像编辑、相册和朋友圈屏，更新 registry 后运行 UI 契约及 frontend 测试。所有临时文件位于 docs/verification/artifacts/2026-09-23/ 下。

## 顺序与所有权

独立候选 .worktrees/avatar-album-release，基线 f6295a6c。头像、公告、朋友圈按互不重叠文件分工；主执行者负责集成、HTML/registry、Git 和发布。继承主目录 62 项已存在修改的 SHA 清单保存在该候选 artifacts/avatar-album-release/inherited-main.json；继承不等于已审查或发布。
