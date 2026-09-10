# UI 与私聊修改复核及纠正

日期：2026-09-10。用户授权：检查 Claude 修改，发现错误自行纠正，重点确保好友发消息与重复会话链路。
依据：`docs/superpowers/plans/2026-09-10-more-menu-direct-chat-moments-empty-chat.md` §4。

## 复核结论

原报告的“修复后不再新增重复房间”超出了实际证据。原实现仍存在以下路径，本次已纠正：

1. 规范目录查询异常被当作无记录、已知规范房间打开异常触发新建、注册冲突房间失败时返回另一个房间。改为传播失败并重试已知房间，避免网络/同步问题触发重复创建。
2. SDK `Room.requestParticipants()` 在 `participantListComplete` 时直接返回缓存，原先的重试和重邀复验不保证获取新成员。适配器在不健康房间与修复后直接查询 `/members`，不再以旧单人缓存误判重邀失败。循环同样使用服务端快照，防止旧双人缓存覆盖服务端三人结果。
3. 规范房间打开仅按 `m.direct` 推导好友；对方退出且映射缺失时目标为空，映射过期时还可能指向错误用户。`app_home` 到网关/适配器现在明确传递所点击好友的 Matrix ID。
4. 本地已有单人或正确双人房间，修复失败后仍显式创建替代房间。现在保留原房间并允许重试；三人/错误对象的非规范本地异常房间沿用现有独立恢复规则，不放松双人加密校验。
5. 朋友圈旧分页失败可覆盖刷新后状态；旧请求结束可干扰新请求的加载标记。以分页世代、Future 身份和操作 token 隔离，并在刷新期间阻止旧游标请求。
6. 朋友圈首屏失败没有提示和重试按钮，首屏加载没有指示器；补回两种状态。`await currentFuture` 移入异常处理范围，重试/重新加载重置分页标记。后台缓存刷新 `setState` 使用块体，避免返回 Future。
7. 菜单横屏大字体发生垂直溢出；增加滚动容器，宽度尊重屏幕上限，换行文字居中。保留既有外观菜单定位键与行为。

Empty chat 名称回退保留原实现：没有发现必须改动该 helper 的错误。它只处理可识别私聊的显示名，不改变删除好友、隐藏聊天或删除聊天的语义，也不合并历史房间。

## 拥有与修改的文件

- `apps/mobile_flutter/lib/features/matrix/direct_chat_controller.dart`
- `apps/mobile_flutter/lib/features/matrix/matrix_direct_chat_adapter.dart`
- `apps/mobile_flutter/lib/app_home.dart`：仅规范房间 opener 的 peer 接线。
- `apps/mobile_flutter/lib/features/moments/moments_page.dart`
- `apps/mobile_flutter/lib/ui/components/wechat_more_sheet.dart`
- 对应 direct chat、canonical readiness、moments pagination、more sheet 测试，以及计划与本验证文档。

## 红绿证据

日志目录：`docs/verification/artifacts/2026-09-10/direct-chat-review/`。

- `red-gateway.log`：四个失败，证实目录错误/规范打开错误/冲突错误/重邀失败仍返回替代房间。
- `red-members.log`：缓存仍单人而服务端重邀成功时，原实现抛 `Canonical room is not a healthy direct chat`。
- `red-authoritative-members.log`：服务端三人快照被后续双人缓存覆盖，错误返回成功。
- `red-ui.log`：旧分页失败污染刷新后的状态、横屏菜单溢出；其中 success 分支最初因惰性列表视口断言失败，已改为验证真实下一页请求次数，不把此项计作产品缺陷。
- `red-initial-feed.log`：首屏 HTTP 失败后找不到重试入口。
- `green-core-final.log`：最终直聊核心 27 个测试通过。
- `green-ui-final.log`：朋友圈目录及菜单 47 个测试通过。
- `analyze.log`：静态检查通过。首轮发现的新增格式规则与测试字段覆盖警告已修正。
- `flutter-full.log`：中间版本全套 1435 个测试通过；其后新增服务端快照与首屏失败回归。
- `flutter-full-final.log`：最终全套 **1437 passed**，退出码 0。
- `analyze-final-mobile.log`：最终 `flutter analyze` **No issues found**，退出码 0。最后一次调整仅为测试 if 增加大括号，未改变测试行为。
- `verify.log`：`pwsh.exe -NoProfile -File scripts/verify.ps1` 最终 **Verification: PASS**，退出码 0。日志保留测试自身的跳过项和既有依赖弃用警告，不将脚本通过等同于生产端到端验收。
  - Business API/Worker：1498 passed、36 skipped、1 warning；Flutter boundary：67 passed。
  - 既有警告为 Starlette httpx 集成与 Getui bridge 的 Pydantic class Config 弃用提示，与本次 Flutter 修改无关。
- `source-hashes.json`：最终受本次修改影响的源码与测试 SHA-256，供无 Git 工作区比对。

## 评审

按顺序完成规格符合性和独立质量/安全复核。规格检查确认 Matrix/业务边界、加密及双人成员验证保留，无资金/认证/密钥机制变更。独立质量评审指出服务端快照被后续缓存覆盖的问题，本次通过红绿测试修正；同时补上首屏失败重试测试，并纠正目录注册注释的过强保证。

## 实际保证范围与尚未验收项

- 上述已证实的客户端错误路径已有自动化验证，不能替代 `superJJ → 这个小鸿` 在真实设备与对应服务端数据上的验收。本次未登录该真实账号、未读取消息明文，未部署或打包。
- 两个历史真实 Matrix 房间仍保留，未自动 leave/forget、删除、隐藏或合并。打开规范房间的修复不会自动处理历史重复记录。
- 双设备同时首次查询到无规范记录后，各自建房的竞态仍存在；当前业务注册实现会覆盖既有映射。单靠客户端错误处理不能提供全局唯一创建保证，本次未修改该后端契约。
- 对确定无法加入/没有修复权限的规范房间，当前返回失败保留数据，需核实实际房间成员与权限后再做恢复，不能靠每次新建绕过。
- 最终真机验收：双方先后打开同一好友会话、互发加密消息、连续点击、退出页面再开、重启应用、模拟慢同步、恢复网络；比较规范 roomId 与新建次数，确认重试不创建第二个房间，并检查两个历史房间的消息仍可访问。
