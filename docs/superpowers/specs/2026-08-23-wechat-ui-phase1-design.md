# ChatFlow 微信式 UI 分阶段优化设计

**状态：** 已批准（用户于 2026-08-23 确认阶段顺序与阶段一原型）
**产品：** 畅聊 ChatFlow
**视觉基准：** 微信 iOS/Android 最新版公开交互模式，落地时使用现有 WeChat tokens、Cupertino 组件和 Figma 导出账本，不复制受版权保护的实现代码或素材。

## 1. 目标与阶段顺序

本设计把九项 UI/交互需求拆成三个可独立验证的阶段：

1. **阶段一（本计划先实施）：资料、好友设置、聊天信息**：拍一拍资料字段、备注即时同步、微信式标签多选管理、删除确认规范、私聊头像进入完整好友资料、移除聊天信息页拍一拍入口。
2. **阶段二：搜索与日期选择器**：私聊/群聊历史搜索重做、全局搜索、日期分组与滚轮 DatePicker、加载更多与定位高亮。
3. **阶段三：群成员实时同步**：成员增删后的聊天信息即时刷新、群主/管理员排序、新成员位置与状态更新。

阶段之间通过公开接口衔接；阶段一不改变 Matrix 加密边界或账本事实来源。

## 2. 阶段一交互设计

### 2.1 拍一拍

- `ProfileData` 增加可空 `nudgeSuffix` 字段；`ProfileGateway.loadProfile` 和 `updateProfile` 负责读取/保存。
- `ProfilePatch`/`ProfileResponse` 增加 `nudge_suffix`，长度限制 32 个 Unicode 字符；空字符串表示清除。
- 入口只保留在“我 > 设置 > 个人信息”的独立列表条目“拍一拍”；进入编辑页后使用微信式单行输入、取消/保存，保存成功后立即显示摘要。
- `DirectChatInfoPage` 删除“设置拍一拍”条目；聊天消息展示层只消费已加载的个人资料字段，不提供编辑入口。
- 保存失败保留草稿并在页面内显示明确错误“拍一拍设置保存失败，请重试”。

### 2.2 好友备注

- 好友资料页 > `…` > 好友设置 > 备注进入独立编辑页，不再用不可追踪的临时对话框作为唯一编辑界面。
- 保存调用现有 `PATCH /friends/{friend_id}`，成功返回权威 `ContactDetails`；资料页、联系人列表和会话标题通过同一缓存更新，立即显示新备注。
- 网络或校验失败显示“备注保存失败，请重试”，不覆盖上一次成功值。

### 2.3 微信式标签多选

- 好友设置 > 标签进入 `ContactTagPickerPage`：顶部“完成”，列表第一项“新建标签”，其后为账户标签，支持勾选多个当前好友标签。
- 新建、重命名、删除均通过业务 API；删除前使用居中 Cupertino 确认弹窗。标签选择完成后一次性调用 `PATCH /friends/{friend_id}`，返回值更新好友资料与联系人缓存。
- 标签摘要按稳定顺序显示；联系人页提供按标签筛选入口，筛选结果由权威联系人列表计算。
- 兼容现有 `GET/POST/DELETE /contact-tags` 和好友 `tags` 字段；如需重命名，增加非破坏性的 `PATCH /contact-tags/{tag_id}`。

### 2.4 删除与资料跳转

- 删除好友按钮水平居中，红色文字与图标均居中；所有删除类操作统一使用居中的取消/删除按钮。
- 删除确认文案：标题“删除好友”，内容“删除后将不再显示在你的通讯录中，且需要重新发送好友申请。”，按钮“取消”“删除”。成功后返回联系人列表并移除缓存项；失败显示明确错误且保留页面。
- 私聊聊天信息页头像/昵称区域均进入完整 `ContactProfilePage`，展示头像、昵称、畅聊号、地区、个性签名及操作按钮；头像不再只打开大图。

## 3. Figma 参与方式

Figma 是视觉事实源，不是事后截图：

1. Agent 在开始每阶段前检查目标页面、组件、变量和现有实例，记录节点 ID、Figma Key、状态和 Token 映射。
2. Agent 使用现有 Figma 文件 `zpzwTbnj1hqx80tyRygX78` 的导出账本 `design-demo/artifacts/figma-state.json`；阶段一新增/更新页面登记：`Profile / Personal Info / Nudge`、`Contact / Tag Picker`、`Contact / Delete Confirmation`、`Chat Info / Friend Profile Entry`。
3. Flutter 实现只消费注册表中的语义颜色、字体、间距、圆角和组件名称；禁止为阶段一页面新增硬编码视觉值。
4. Agent 完成导出后运行 UI contract drift 校验并把 ledger、截图/节点清单写入 `docs/verification/<date>-ui-review.md`。
5. 开发者只审查 Figma 视觉质量（层级、间距、状态、动效、iOS/Android 一致性），在 PR 描述或直接提交审查记录中签署 PASS/FAIL；开发者不负责导出或同步。

当前仓库未暴露可调用的实时 Figma MCP 工具，因此阶段一实施前的节点更新以版本化导出账本为可审计输入；一旦 Figma MCP 可用，Agent 必须先执行只读节点/变量检查，再执行写入和截图验证。

## 4. 验收标准

- 阶段一 Flutter widget/controller tests 覆盖：拍一拍字段读写与失败保留、聊天信息页无拍一拍入口、备注保存后资料/联系人同步、标签多选 CRUD 与筛选、删除居中和确认逻辑、头像跳转完整资料。
- Figma ledger 登记阶段一页面数量、组件名称、状态和 Token；`scripts/verify_ui_contract.py` 校验品牌、Token、页面登记和 Figma/Flutter/HTML 映射。
- `flutter analyze`、聚焦 Flutter tests、`npm test`（如 HTML 合约受影响）和 `pwsh -NoProfile -File scripts/verify.ps1` 全部退出码 0。
- 阶段二、三在阶段一合并后分别建立自己的失败测试、Figma 审查记录和可回滚提交。

## 5. 非目标

本设计不改变 Matrix 事件协议、E2EE 密钥边界、CAIBI/点钻账本、OpenAPI 标题、健康检查 service、Docker 默认服务名或 TOTP issuer。
