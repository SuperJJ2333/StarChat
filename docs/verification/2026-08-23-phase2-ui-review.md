# 阶段二 UI/Figma 审查记录

## 范围

- `GroupChatHistorySearchPage`：搜索框、日期分组、日期筛选、记录定位回调。
- `WeChatDatePicker`：滚轮选择、取消/确认操作。
- `GlobalSearchPage`：好友、群聊、聊天记录分组及相关度排序。

## 结论

| 检查项 | 结果 | 证据 |
|---|---|---|
| Flutter 组件与 Token | PASS | `python scripts/verify_ui_contract.py` → `PASS (10 components, 326 screens)` |
| 日期选择器状态 | PASS | `test/ui/wechat_date_picker_test.dart` |
| 历史搜索分组/定位 | PASS | `test/features/matrix/group_chat_info_test.dart` |
| 全局搜索入口与分组 | PASS | `test/features/search/global_search_page_test.dart` |

## Figma 导出账本

- 登记：`phase2-chat-history-search`、`phase2-wechat-date-picker`、`phase2-global-search`。
- 文件：`design-demo/artifacts/figma-state.json`。
- 三方注册表：`packages/ui-contracts/changliao-component-registry.json`。
- 当前环境未调用实时 Figma API；本审查以版本化导出账本和契约校验为准。

## 开发者门禁

PASS：Flutter 分析无问题，阶段二聚焦测试全部通过。视觉原型由开发者按导出账本检查。
