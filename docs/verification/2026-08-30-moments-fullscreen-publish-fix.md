# 朋友圈全屏 / 发布失败 / 返回导航修复 — 验证证据（2026-08-30，版本 0.3.5）

## 1. 朋友圈隐藏底部导航栏

- 「发现 → 朋友圈」（长按菜单与列表项两处）、「我 → 朋友圈」共 4 个入口全部改为 **rootNavigator 全屏推入**（`fullscreenDialog: true`）：朋友圈覆盖整个 Tab 壳，底部导航栏随之隐藏，内容区全屏。
- 退出朋友圈返回「发现」后，底部导航栏随 Tab 壳恢复，可正常切换页面。

## 2. 发布失败「动态不存在」（根因与修复）

**根因**（生产复现于后端代码路径）：`POST /moments` 创建路由在插入动态后调用了 `service.detail(user, row.id)` 校验返回；而 `detail()` 仅允许 `status == "PUBLISHED"` 的动态可见。**带图片的动态创建时状态为 `PENDING_REVIEW`（待审核）** → detail 抛 404 `MOMENT_NOT_FOUND`（"动态不存在"）→ 发布接口整体失败。纯文字动态状态为 PUBLISHED 故能成功——这正是"有时能发有时不能"的表象来源。

**修复**：创建路由改为直接返回新建动态的 DTO（新开会话读取该行），不再经过仅限 PUBLISHED 的 detail 可见性校验。发布语义正确：作者刚创建的动态理应回显，无论是否进入待审核。
- 回归测试：`test_create_with_images_returns_dto_without_not_found`（带图发布 → 201 + status=PENDING_REVIEW + 内容回显），moments 全量 9 项通过。

## 3. 发布页退出返回朋友圈

- 朋友圈改为 root 全屏路由后，发布页（由朋友圈页推入，同一根导航栈）退出时 `Navigator.pop` 回到的下层路由就是朋友圈页，栈结构不再有跨栈错位。
- 退出保护链保留：`PopScope` + `_onBack`（草稿保存询问）→ 正常退出回朋友圈页，不会跳到发现页。

## 4. 验证与发布

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found |
| `flutter test` | 389 passed |
| `pytest tests/business_api/moments` | 9 passed（含新增带图发布回归） |
| `pytest tests/business_api/friendship` | 14 passed |
| 生产部署（备份 `backups/20260830T…`） | business-api 重建；`POST /moments` 带图发布修复上线 |
| 下载页 | `ChatFlow-0.3.5` 三架构包上线，0.3.4 下线；域名验证 PASS |
| 更新推送 | `latest=0.3.5/build 8, min_supported=3` 已发布（PUBLISH 200 / LATEST 200） |

## 5. 遗留事项（非阻塞）

- 朋友圈右上手势区：进入后下拉关闭（fullscreenDialog 自带向下滑动手势）与右上角相机入口并排，符合微信交互。
- 后续如需"发布成功后自动刷新朋友圈信息流"，可在 `didPublish == true` 分支外增加局部 Feed 增量插入（当前为整页刷新，已可接受）。
