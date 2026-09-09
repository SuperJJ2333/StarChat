# 共享媒体输入与用户展示验收记录

工作分支：`codex/redmi-polish-20260909`；基线 `ea8a4481`。规范与计划为同名 `2026-09-09-shared-media-identity.md`。

## 改造与验收证据

| 要求 | 实现与实际结果 |
| --- | --- |
| 同一表情面板及字符集 | 评论/回复直接实例化 ChatEmojiPanel，使用聊天内置完整目录；删除原来硬编码的 8 个表情。光标插入及实际共享面板测试通过。 |
| 同一相册与处理 | 评论直接导航 ImagePickerPage；聊天与评论共用 prepareGalleryMedia。测试覆盖组件实例、原图选择、GIF MIME/字节、取消。 |
| 动画支持 | 内置 animated WebP 目录复用；相册 GIF 不转 JPEG，评论缩略图、大图仍保留动画字节。端到端 API 测试验证 2 帧文件上传、绑定评论及读取字节完全一致。 |
| 失败/重试 | 保留文字和附件，复用完成上传标识与评论幂等键；取消、页面销毁、切换账号测试通过。 |
| 统一身份层 | ProfileRepository.resolveIdentity 按业务 ID / Matrix ID 查询；备注优先，公开名称与本机名称分离。缺失头像字段与明确删除区分。 |
| 更新与缓存 | 按账号生成头像缓存标识；同人替换保留已显示头像；换人/显式删除清除旧图。并发请求代次阻止旧结果覆盖新结果。 |
| 关键页面 | 信息流/评论/点赞/回复、好友搜索/资料、个人朋友圈、聊天记录/成员筛选、分享选择/确认、群成员页订阅同一身份仓库。 |
| 私有备注边界 | 服务端公共作者投影不含备注；本机渲染才覆盖。提及选择界面显示备注，但发送 token 使用公开昵称；测试断言正文不含私有备注。 |
| 媒体权限 | GIF 走已有实时朋友圈可见权限；“不给谁看”后旧媒体链接不可读。不存在绕过访问控制的共享上传地址。 |

## 测试先行及审查

- 新 GIF API 测试初始 5 项失败（不接受 image/gif，契约无 GIF），随后通过。截断后续帧、缺失 trailer、帧越界、伪造 MIME、超量流读取均记录失败后修复；最终 GIF 与旧媒体测试 15 项通过。
- 共享身份测试先复现加载前覆盖、缺失头像降级、空白备注、并发旧请求覆盖；最终另补冷启动并发预加载/静默刷新两项失败测试，修复后仓库 31 项通过。
- 转发列表、确认弹窗、头像复用、同人换图、聊天记录实时更新、提及正文隐私测试均有失败/通过证据。
- 评论缩略图先检测到无界 MemoryImage，修复为有界 provider；DPR 2/5、原始字节保留测试通过。
- 规格审查后进行质量/安全审查；发现的 GIF EOF 差异、并发旧响应、同人头像闪动、成员筛选快照、私有提及和预览内存问题均已修复。
- 首轮全量 Flutter：1596 通过、3 项旧断言失败。复核服务端 `_user_projection` 及 remark-free API 测试后，纠正公开昵称和账号缓存键断言；对应 18 项通过。最终全量 **1615 项通过**（包括随后新增的冷启动测试），`flutter-final.log`。

整库日志：`docs/verification/artifacts/2026-09-09/shared-media-identity/`（不进入 Git）。Flutter analyze 无问题；冷启动最终改动再次定向分析无问题。UI 契约通过：17 components / 330 screens。

`scripts/verify.ps1` 已运行，后端 **1501 通过、37 跳过**。原移动边界检查要求页面直接引用 `contact?.displayName`，与本次共享仓库接线不符，结果为 65 通过/1 失败。检查已改为验证当前账号仓库解析与公开提及边界，5 项对应测试通过。仓库脚本本身未改动；从移动边界检查开始提取原脚本剩余步骤到产物目录执行，避免重跑未受影响的后端 10 分钟测试。**续跑 PASS**：移动边界 66 项通过，UI 契约、API 导入、197 个 Python 文件 AST、迁移单一 head/离线 SQL、OpenAPI、Docker Compose 校验通过。首次脚本运行仍按失败保留，`verify.log` 与 `verify-remaining.log` 合并构成完整检查证据。

已知原有工具提示：Flutter SVG 测试的 filter 元素提示；后端 Starlette/httpx 和 Alembic path_separator 弃用提示。没有把 37 项跳过视作通过，也没有忽略新增测试失败。

## 真实设备与交付边界

- 本次只读检查确认 Redmi `cbd0156b` 在线，`com.liuhetong.mobile` 仍未安装；前一任务误卸载后的恢复安装问题未解决，详见 `2026-09-09-payment-pin-redmi.md`。本次未卸载、清数据或使用正常包名执行 flutter drive。
- 本次真机操作回归未执行，不声明无卡顿、无闪退已经在 Redmi 验证。MIUI 安装许可仍需设备侧允许。
- 本次没有发布 Android 正式更新或 iOS 更新；生产 API 尚未部署本次 GIF 变更。
- Figma 远端未修改：本会话没有可调用编辑工具。复用现有组件，已更新本地 ledger 和 registry；远端同步待完成。此项来自仓库 `figma-ui-delivery` 技能（`D:/pythonProject/outsource/StarChat/.agents/skills/figma-ui-delivery/SKILL.md`）要求：“Every UI change **must use Figma** before code is finalized”。工具不可用不代表远端同步已经完成。
- 既有设计节点：[聊天](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78/ChatFlow?node-id=18-7)、[通讯录](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78/ChatFlow?node-id=19-3)、[朋友圈](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78/ChatFlow?node-id=19-4)。这些链接仅标明对应设计位置，不代表此次远端变更证据。

本地设计记录：`frontend/artifacts/figma-state.json`；组件契约：`packages/ui-contracts/changliao-component-registry.json`。
