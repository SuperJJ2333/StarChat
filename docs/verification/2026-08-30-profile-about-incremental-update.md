# 个人资料 / 关于畅聊 / 增量更新通道 — 验证证据（2026-08-30）

## 1. 「我」页面新增入口

- `ProfileExperiencePage` 新增分组（key：`me-profile-row` / `me-about-row`）：
  - **个人资料** → `PersonalProfilePage`（`personal_profile_page.dart`）：头像（跳转既有头像页）、昵称（弹窗编辑走业务 API 保存）、性别（男/女/保密）、地区（省份列表）——性别/地区 v1 存于客户端本地（SharedPreferences，`profile-gender`/`profile-region`）；畅聊号/邮箱只读展示；拍一拍入口保留。
  - **关于畅聊** → `AboutChangliaoPage`。

## 2. 关于畅聊两级页（微信"关于微信"风格）

- `AboutChangliaoPage`：品牌标识 + 「当前版本 V0.3.2」行（key：`about-version-row`），点击进入「关于」详情页。
- `AboutDetailPage`：Logo/名称/`V0.3.2 (Build 5)` 版本信息 + 两个入口：
  - **投诉**（`about-complaint-row`）→ `ComplaintPage`：微信式投诉类型单选（发布不实信息/涉嫌欺诈骗钱/存在侵权行为/骚扰行为/其他问题）+ 300 字描述 + 提交；提交成功展示"投诉已提交"完成页。
  - **版本更新**（`about-check-update-row`）→ 手动检查 `GET /app-updates/latest`：有新版弹既有更新弹窗，无新版弹「当前已是最新版本」。

## 3. 投诉后端

- 表 `complaints`（迁移 **0033_complaints**，幂等 DO 块，expand-only）；模型 `Complaint`。
- 端点 `POST /api/v1/support/complaints`（登录，category 白名单校验 422 `COMPLAINT_CATEGORY_INVALID`，描述 ≤500）。
- 测试 `tests/business_api/test_complaints.py`：401 / 落库 / 类型校验；生产部署后探针：未登录 401 ✓、迁移 head=0033 ✓、complaints 表已建 ✓。

## 4. 增量更新机制（资源差异通道 + 全量回退）

- 语义（诚实边界）：**非代码资产**（表情包/文案/配置类资源）支持增量——客户端启动静默拉取 `downloads/resources/<build>/resource-manifest.json`，仅当清单 `base_build == 当前构建` 且未应用过该版本时，逐文件比对 sha256，仅下载缺失/变更文件（校验通过才落盘，单文件失败不阻塞）。**代码级变更（Dart 编译产物）无法文件级增量，回退既有全量 APK 通道**；首次安装/跨大版本同样回退。
- 实现：
  - `lib/features/update/resource_update_service.dart`：`ResourceUpdateService.apply`（差异计算/sha256 校验/应用版本记录）＋ `ResourceUpdateGateway` 接口；
  - `network_resource_gateway.dart`：生产实现（清单与文件托管于下载站 `downloads/resources/<build>/`，本地落盘文档目录 `hot-resources/`）；
  - `app_home.dart`：启动静默应用（失败不影响主流程）。
- 服务端：`downloads/resources/5/resource-manifest.json`（54 个表情 GIF，sha256 清单，version=5/base_build=5）已发布并可公网访问。
- 测试 `resource_update_service_test.dart`（5 项）：基线不匹配回退全量、同版本静默、仅下载差异、sha256 拒绝篡改下载、首次安装应用增量。

## 5. 验证与部署

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` / `flutter test` | No issues / **374 passed** |
| `pytest tests/business_api`（friendship 14 + complaints 3 + search 6 + ledger 2 + migrations 7） | 全部通过 |
| `verify.ps1` 全量（OpenAPI 已重导出含 complaints 端点） | **PASS** |
| 生产部署（备份 `backups/20260830T050409Z/complaints/`） | business-api 重建；迁移 head=0033；探针：健康 ok、投诉未登录 401、complaints 表已建 |
| 下载站 | `downloads/resources/5/` 清单 + 54 资源上线（公网可访问） |

## 6. 遗留事项（非阻塞）

- 性别/地区为客户端本地资料（v1）；如需服务端化与多端同步，需扩展 Profile 模型与 API（独立迭代）。
- 增量通道当前消费端为表情资源；文案/配置类资源接入只需在清单中登记新路径。
- 代码级补丁（bsdiff/bspatch 原生通道）需新增原生插件，列为后续评估项。
