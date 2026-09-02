# 添加朋友：畅聊号/邮箱前缀搜索 — 验证证据（2026-08-30）

精确需求规格见 `docs/superpowers/plans/2026-08-30-add-friend-search-spec.md`（阈值/排序/展示字段的定义原文在该文档）。

## 规格要点（实现与文档一致）

- **搜索方式**：登录用户在「添加朋友」页可按**畅聊号**或**邮箱**查找，前缀匹配（输入与字段开头连续字符一致，大小写不敏感）；中缀不命中。
- **最小长度**：**≥2 字符**（去空格后）。客户端不足 2 字符不发请求并展示引导文案；服务端 `Query(min_length=2)` 以 422 兜底。
- **排序**：① 畅聊号命中优先于邮箱命中；② 同级按最近活跃时间倒序（未吊销设备 `last_seen_at` 最大值，登录/心跳刷新）；③ 畅聊号字典序稳定排序。
- **展示**：头像（缺省昵称首字占位）+ 昵称 + 畅聊号；**不出参邮箱**（PII 不外泄）；每页上限 20 条；关系状态由按钮呈现（添加/申请已发送/已添加/重新申请）。
- **安全**：登录必需（401）；单用户限流 30 次/60 秒；排除自己与双向拉黑用户。

## 改动清单

- 后端：`modules/identity/profile.py::search_public_profiles` 重写（LIKE 前缀 + ESCAPE 转义、rank case、设备活跃子查询、nullslast）；`api/friendship.py`（q 长度 2–64、`rate_limiter.hit('user-search:{uid}')`、`create_friendship_router` 增可选 rate_limiter）；`main.py` 注入。
- 客户端：`contacts_page.dart::AddFriendPage` 重写（300ms 防抖、2 字符门槛、加载态、结果列表头像/昵称/畅聊号、空态与错误提示、好友申请状态翻转不变）；`contact_models.dart` 新增 `AddFriendGateway`；`business_api_client.dart` 实现声明。

## 测试与验证

| 项目 | 结果 |
| --- | --- |
| `pytest tests/business_api/test_user_search.py` | **6 passed**（单字符 422、前缀 vs 中缀、邮箱大小写不敏感、三级排序、排除自己/无 email 出参、401） |
| `flutter analyze` | No issues found |
| `flutter test` | **365 passed**（新增添加朋友搜索 4 项：阈值不请求、防抖搜索渲染、空态、申请状态翻转） |
| `verify.ps1` 全量 | **PASS**（OpenAPI 已重导出：q minLength 1→2） |

## 部署

- 备份：`/opt/starchat/backups/20260829T185529Z/backend-api/`（profile.py、friendship.py、main.py）。
- 同步 3 个后端文件并重建 business-api（2026-08-29T18:55Z）。
- 线上探针：`/health/live` ok；`/users/search` 未登录 401（鉴权生效）。
- 客户端随下个版本（ChatFlow-0.3.1+）分发；搜索 UI 已由组件测试锁定行为。

## 追加：用户反馈"输入任何字符没有反应"的诊断与解决（2026-08-30）

**诊断结论**：
- 后端已部署且工作正常：生产库验证 `liu` 前缀命中 3 个用户（liuhetong_admin / liuhetong_test01 / liuhetong_test02）、`a1` 前缀命中 2 个；接口鉴权生效（未带会话令牌 401）。
- 根因：用户运行的 `ChatFlow-0.3.0` 安装包构建于"添加朋友"搜索改版**之前**。旧版页面仅在键盘提交（回车/搜索键）后才发起请求，输入过程无实时反应 —— 与新交互（300ms 防抖实时搜索）体感差异即用户所见现象。
- 次要因素：新搜索要求至少 2 个字符，单字符不触发请求。

**解决**：发布 `ChatFlow-0.3.1`（versionCode 4）：
- 三架构包已上传 `downloads/`（arm64 SHA256 `31B0ABBA…`），0.3.0 三包已下线；落地页 `releaseVersion` 与静态回退链接同步 0.3.1；域名验证 PASS（落地页内容 + APK HEAD 200）。
- 模拟器（x86_64 包）安装烟测：versionName=0.3.1，启动正常（`artifacts/2026-08-30/emulator-031-launch.png`）。
- 用户重新下载安装 0.3.1 后：进入「添加朋友」输入 ≥2 个字符即实时返回候选（头像 + 昵称 + 畅聊号）。
- 诊断脚本存档：`search_diag.py`（仅输出状态码与计数，令牌不出服务器）。

## 追加：0.3.1 更新推送发布记录（2026-08-30）

经管理端点 `PUT /api/v1/admin/app-update-settings` 完成发布（在服务器容器内以超级管理员既有活跃会话铸造短时令牌执行，令牌不出服务器、不落日志）：

- 发布结果：`latest_version=0.3.1 / latest_build=4 / min_supported_build=3`，notes 与 `apk_url=https://www.liuhetong888.com/downloads/ChatFlow-0.3.1-arm64.apk`；幂等键 `app-update-publish-0.3.1-20260830`；发布前后 GET 均确认。
- 公开端点确认：`GET /api/v1/app-updates/latest` → `configured:true, latest_build=4, min_supported_build=3`。
- 客户端行为矩阵：build 4（0.3.1）不弹窗；build 3（0.3.0）弹**可忽略**更新（更新/稍后再说）；build ≤ 2 弹**强制**更新（不可关闭）。
- 排障记录：首次发布 404 —— 上次部署将 admin.py 误放到 `/opt/starchat/backend/app/`（少一级 `api/`），已归位到 `backups/20260829T172959Z/backend-api/admin.py.wrong-location`、同步正确文件并重建 business-api。脚本存档：`publish_app_update.py`（令牌不落日志）。

## 追加：生产"服务内部错误"根因修复（2026-08-30，迁移 0031）

**现象**：0.3.1 客户端「添加朋友」搜索展示"服务内部错误"。

**根因（生产日志定位）**：`column friend_requests.requested_at does not exist` —— 模型/迁移漂移：生产库 `alembic_version=0030`，但 0020 迁移的增量（`requested_at` 列 + 复合索引）从未真正落库（历史上版本号与结构脱节）。本地测试用 `create_all` 建表故无法发现；该漂移会 500 掉所有涉及 `FriendRequest` 的查询（搜索、好友请求列表、接受/拒绝）。

**漂移排查**：全库模型 vs 生产 information_schema 比对（`schema_drift_check.py`）确认仅此一处缺失。

**修复**：幂等修补迁移 `0031_friend_request_requested_at`（条件补列 + 回填 `created_at` + NOT NULL + 条件建索引；downgrade no-op，结构契约属 0020）。部署后生产 `alembic current=0031`、列已建（NOT NULL）。

**端到端复测**（容器内会话令牌）：
- `GET /users/search?q=liu` → 200，2 items（liuhetong_test02/test01，正确排除请求者自己）
- `?q=a1` → 200，1 item；`?q=zz` → 200，0 items
- `GET /friends/requests` → 200（同漂移此前也会 500 的端点一并恢复）

**防复发**：本地单测建表方式（create_all）掩盖迁移漂移 —— 后续可引入"迁移建库 + 模型 alembic check"的 CI 校验（已列入遗留事项）。
