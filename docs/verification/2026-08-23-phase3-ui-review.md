# 阶段三 UI/Figma 审查记录

## 范围

- 群聊聊天信息页成员网格及标题人数。
- 添加/移除成员后的原地刷新。
- 群主、管理员、普通成员排序。

## 结论

| 检查项 | 结果 | 证据 |
|---|---|---|
| 成员快照原地替换 | PASS | `replaceMembers` 控制器测试 |
| 添加/移除后人数刷新 | PASS | `GroupChatInfoController.invite/removeMembers` 重新加载权威快照 |
| Matrix 实时同步 | PASS | `Client.onSync` 按房间 ID 过滤并触发 `load()` |
| 排序规则 | PASS | 群主 → 管理员 → 普通成员，名称不区分大小写排序 |
| Flutter 分析 | PASS | `flutter analyze` → `No issues found!` |

## Figma 导出账本

- 登记：`phase3-group-member-live-sync`。
- 文件：`design-demo/artifacts/figma-state.json`。
- 三方注册表：`packages/ui-contracts/changliao-component-registry.json`。
- 当前环境未调用实时 Figma API；本审查以版本化导出账本和契约校验为准。

## 开发者门禁

PASS：阶段三聚焦测试通过，页面继续消费现有 WeChat Scaffold 与 Token。
