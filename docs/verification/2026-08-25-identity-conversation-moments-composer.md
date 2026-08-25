# 2026-08-25 身份、会话与朋友圈发表页验证

## 范围

验证规格 `docs/superpowers/specs/2026-08-25-identity-conversation-moments-composer-design.md` 对应的共享身份缓存、好友备注实时刷新、消息列表显示、群聊命名、朋友圈当前账号身份以及微信式发表/可见范围流程。

## 测试先行证据

- 身份缓存红灯：新增测试最初因 `addListener`、`applyUpdatedContact`、`refresh`、`ChatIdentityCacheError` 与 `ContactDetails.toSummary` 不存在而编译失败；实现后定向测试通过。
- 通讯录红灯：`ContactsPage` 最初不接受共享缓存；实现订阅后联系人备注无需重建 App 即更新。
- 会话展示红灯：`conversation_presentation.dart` 不存在，群导航仍显示自定义名称；实现后标题、副标题、撤回和系统事件规则测试通过。
- 朋友圈身份红灯：`MomentsPage` 不接受共享身份缓存；实现后当前用户 nickname/头像映射测试通过。
- 发表页红灯：三个新页面文件及选择模型不存在；实现后发表、可见范围、标签/朋友选择与失败保留测试通过。

## 新鲜验证结果

| Command | Result |
| --- | --- |
| `flutter analyze --no-pub`（`apps/mobile_flutter`） | PASS，`No issues found` |
| `flutter test --no-pub --reporter compact`（`apps/mobile_flutter`） | PASS，286 tests |
| `pytest tests/mobile -q` | PASS，21 tests |
| `pwsh -NoProfile -File scripts/verify.ps1` | PASS |
| Matrix Bot suite（由 `verify.ps1`） | PASS，9 tests |
| Business API + Worker（由 `verify.ps1`） | PASS，182 passed、1 skipped |
| Flutter/HTML/Figma contract（由 `verify.ps1`） | PASS，17 components、326 screens |
| Alembic offline upgrade / OpenAPI drift / Docker Compose render | PASS |

全量 Flutter 首次运行暴露一个既有 Matrix 登录令牌测试夹具缺少服务端必填 `matrix_user_id`；生产 FastAPI `MatrixLoginTokenResponse` 与 Flutter 解析均要求该字段。补齐夹具并增加返回值断言后，定向测试及全量测试通过。

最终独立代码审查发现并修复：带图发表漏传图片、备注成功回写延迟及失败异常外泄、私聊页固定 Matrix 标题、Profile 无缓存失败缺少重试、未解密事件泄露异常正文、身份缓存日志携带原始异常。新增 5 类回归断言后，41 项定向测试、286 项 Flutter 全量测试与完整仓库门禁均通过。

仓库门禁首次运行拦截新可见范围页使用 `CupertinoButton.filled`；按移动端架构边界改为共享 `ModernActionButton` 后，21 项边界测试及完整 `verify.ps1` 通过。

## 规格符合性审查

- 当前账号封面身份仅来自 Business Profile；不使用好友备注或 Matrix 展示名。
- 好友显示按上下文执行：联系人/私聊 `remark → nickname`，用户名仅作为异常数据防御回退；发送者正常路径不把 username 当 nickname。
- 群列表包含当前登录用户在内的已加入成员并以 `、` 连接；聊天导航固定 `群聊(人数)`；群信息空显式名称显示“未命名”。
- 群副标题在未读大于零时使用 `[N条]名字：内容`，零未读省略前缀；撤回无冒号；角标仍由原独立字段渲染。
- 朋友圈发表页只保留“谁可以看 / 添加链接”；公开/私密与定向/排除之间有独立间隔；定向/排除为二级页面，不是父页单选项。
- 标签/朋友页包含双列切换、搜索、多选、计数与完成；选择仅在完成后回传，系统 Back 自然丢弃页面内未提交集合。
- 发表、草稿、身份刷新和标签/朋友加载失败均保留上一成功状态或用户输入，并提供可重试错误；日志不包含令牌、消息正文或 URL 查询参数。

## 质量与安全审查

- Business API 仍是 profile/contact/moments 的身份权威；Matrix 只用于加密通信成员及明确的展示回退。
- 本次未修改账本、红包、钱包、认证策略、Matrix 密钥或加密边界。
- 共享缓存只持久化非敏感身份元数据；错误日志仅含操作名、匿名账户指纹、异常类型与堆栈。
- 发布接口沿用既有幂等键生成逻辑；新增传递的标签 ID 与链接字段已由当前 FastAPI `CreateMoment` 契约支持。
- Figma 本会话无读写工具。已在 `docs/figma/chatflow-ui-delivery-registry.json` 与 parity ledger 记录既有 Moments 节点 `29:5798`、批准的浏览器对照稿和真实阻塞状态；未伪造远端更新或新节点。

## 发布阶段

### 公网 Docker

- 通过 `ssh -p 23421 root@207.56.8.8` 在 `/opt/starchat` 执行生产 compose 只读状态检查。
- `business-api`、`business-worker`、`business-postgres`、`business-redis`、`synapse`、`postgres`、`element-web`、`mailpit` 均为 running/healthy；`gateway`、`matrix-bot`、`coturn` 为 running。
- 本次生产代码没有服务端或 compose 变更，因此未做无意义容器重建；公网现有后端继续提供移动端所需契约。

### APK 与模拟器

- Release APK：`apps/mobile_flutter/build/app/outputs/flutter-apk/app-release.apk`，137,692,120 bytes，SHA-256 `99C5EF7E851D7B8D23C1293EC25CE92CB31ADD9B739DBC3C67CD668ECCB6A035`。
- Debug APK：`apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk`，242,590,330 bytes，SHA-256 `D167561C173DC498504D675568701B9EA5EE02D827A055B52DE7982EA8832454`。
- 两个 APK 均使用公网 origin `https://liuhetong888.com` 构建。Release 安装被 Android 以 `INSTALL_FAILED_UPDATE_INCOMPATIBLE` 拒绝，原因是模拟器现装包签名不同；为保留现有登录数据，没有卸载应用。
- 将同源 Debug APK 覆盖安装到 `emulator-5554` 成功；包名 `com.liuhetong.mobile`，`versionCode=1`、`versionName=0.1.0`，最终更新时间 `2026-08-25 09:19:18`。

### 模拟器 UI 证据

证据目录：`docs/verification/artifacts/2026-08-25/identity-conversation-moments-composer/`。

| Artifact | 验证点 | SHA-256 |
| --- | --- | --- |
| `discovery.png` | 发现页可进入朋友圈 | `0471BDF7394E614ABB4061842D9775635B4CB2CD8CC0054996FB4CCE1B8FD349` |
| `moments-owner.png` | 朋友圈封面显示当前账号头像与 nickname，不显示固定“畅聊朋友圈” | `64BEF0126DD5EE0CE6D4C38B2AA31C13B465B4486614320C05D9BF65895A9BD5` |
| `composer.png` | 微信式发表页仅保留“谁可以看 / 添加链接” | `007BBA8B8DC3896204093A3DECAD13133CFDEBE7C54228EEEF1F2041152E9C36` |
| `audience.png` | 公开/私密与只给谁看/不给谁看分组，后两项为二级入口 | `401309D1FD2F03BFEA22A81265805400D27A432D76951FD7A28EE429208A5564` |
| `audience-selector.png` | “只给谁看”二级页和完成计数；过期会话触发明确可重试失败态 | `82779CBBFD80A5267C60F9EB8C4BE5651D148B39F85779DFC526FD2C26748EE2` |

模拟器已有生产刷新令牌在验收期间被服务端判定为重复使用/无效，因此在线标签和朋友请求进入“标签或朋友加载失败，请检查网络后重试”的保留状态；没有卸载清数据，也没有绕过认证。静态导航与失败态完成实机验证，标签/朋友双列、搜索、多选和完成回传由 Flutter widget/model 测试覆盖。最终包安装后，权威刷新拒绝按安全策略清除失效 Business 会话并回到登录页；清空 logcat 后重新启动检查 `FATAL EXCEPTION|Unhandled Exception|FlutterError` 为 0。日志中没有令牌值、消息正文或 URL 查询参数。

### 2026-08-25 公网同步部署

- SSH `root@207.56.8.8:23421` 恢复后，将 `7161ae6..ef7e515` 中 35 个现存受控文件同步到 `/opt/starchat`；被新两级可见范围页面替代的 `moment_audience_picker_page.dart` 在备份后删除。
- 同步包 SHA-256：`CC63C7B0D4F012D46D49EDB188FC0F357D834517879E2B8CD4BB8C43E52EF272`。远端抽查 `moment_composer_page.dart`、`chat_identity_cache.dart`、`contacts_page.dart` 的 SHA-256 与本地逐项一致。
- 部署前备份：`/opt/starchat-backups/source-before-ef7e515-20260825T035750Z.tar.gz`。
- Release APK 发布为 `/opt/starchat/releases/mobile/starchat-ef7e515-release.apk`，`latest-release.apk` 指向该文件；远端大小 137,692,120 bytes，SHA-256 `99C5EF7E851D7B8D23C1293EC25CE92CB31ADD9B739DBC3C67CD668ECCB6A035`。
- 服务器没有既有 APK HTTP 下载路由，本次没有修改公网 Nginx 契约；APK 作为受控发布制品保存在服务器。后端与 Compose 无代码变化，因此没有重建或重启生产容器。
- `docker compose ... config --quiet` 通过；Business `/health/live` 与 `/health/ready` 均返回 `ok:true`；11 个容器全部 running，带健康检查的服务均为 healthy。
- 外部 `scripts/verify_public_domains.ps1` 全部通过：三个域名 DNS、HTTP→HTTPS、Business live/ready、Matrix versions/discovery 均成功，管理端与 Synapse 管理 API 继续保持不可公开访问。
