# 2080 基线会话交互与分支收敛

## 基线与合并

用户要求保留历史、合并分支、修复编译并推送 main，清理不再需要的分支。本次在 `.worktrees/integrate-main-20260910` 的 main 操作，原始目录的钱包/媒体工作及 iOS 未提交工作未纳入发布或覆盖。

合并提交 `094a823f` 继承 `10316dda` 和 `5fbb2953`（2080 清除本地状态后显式重新登录修复），同时保留 2077、2079 的朋友圈与视频修复。Gradle 冲突保留并行 Debug 包和中文标签，测试冲突保留 SharedPreferences 初始化及新增登录断言；合并后 Matrix client factory 55 项通过。完整祖先、远程和工作树审计见 `2026-09-10-branch-audit.md`。

## 行为验收

- 置顶与手动未读先发布本地状态，持久化后后台按房间串行同步；陈旧同步不会覆盖尚未确认的操作，失败在后续同步重试。相同账号新客户端可恢复待同步偏好；坏 JSON/坏条目回退到服务端数据。
- pinnedAt 倒序，置顶总在普通会话前；私聊、群聊共同使用 #EDEDED / #191919 置顶背景。取消置顶清理时间戳并恢复普通排序。
- 手动未读使用正常红色数字气泡；实际进入成功才清除。挂起网络的真实消息页测试在 100ms pump 内验证置顶、反序排序、未读和取消置顶。此为自动化帧级证据，不冒充真机实测延迟。
- Messages/Contacts/Discovery 共用纵向四项菜单（发起群聊、添加朋友、扫一扫、外观），均接入真实页面动作；208dp 宽、52dp 最小行高、整行点击、同一分隔线、120ms 动画，支持大字和窄屏。
- 底栏长按消息调用系统 mediumImpact 和 300ms 缩放；消息页未显示时也清空所有已加入会话的手动/正常未读和总数。新消息恢复正常计数；不同账号的同一房间不会互相继承清零抑制。
- 退出保留原确认，再默认选择保存；显式确认删除为红色粗体。保存保留设备聊天及加密状态。删除使用现有 ADR-0007 公共清理接口，并增加账号媒体/偏好清理；与其他账号磁盘目录隔离，后台旧写入无法复活删除文件。
- 删除失败也完成退出，登录页保留“已退出登录，本机数据未完全删除”提示。未声称闪存取证擦除、删除用户已导出文件或服务端密文。未在真实账号上执行删除或发送消息。

## 测试与复核

日志集中保存在 `artifacts/2026-09-10/conversation-state-main/`；子任务最初写到原始目录同名 artifacts 的日志已复制到此目录，保留原件。原始目录没有本次生产代码修改。

- 置顶排序及等待网络回归、偏好删除回归、账号串状态与坏 JSON 回归先红后绿；90 项定向/生命周期测试通过，最终账户修复后 24 项通过。
- 退出/底栏/媒体组合 120 项通过；新增明确登录页断言后的退出 8 项通过；独立审查重跑 19 项通过。
- 顶部菜单/通讯录/发现 22 项通过；HTML 119 项通过；UI 合同 20 组件 / 331 页面通过。
- 初次完整 Flutter 1812 通过、1 项旧 session gate 测试仍假设单弹窗。按新流程增加“第一确认不退出、保存后退出”断言，相关 13 项通过；最终全量结果下方补记。
- 完整 analyzer 无问题。规格复核先于质量/安全复核；独立审查发现的磁盘缓存遗漏和退出后错误提示丢失均已修复，并补充晚到写入、跨账号保护及页面销毁回归。
- 后端无生产修改，仓库 `scripts/verify.ps1` 仍完整执行。依赖已有的 Kotlin/Java 弃用提示、Starlette httpx 和 Alembic 配置警告分别保留在构建/测试日志，不以静默忽略代替功能检查。

## 设计与交付

更新 `UI_DESIGN.md` 16.2、Flutter 公共组件、HTML 顶部菜单/确认框/底栏状态、注册表和本地设计台账。现有 Figma 参考页：[消息 18:7](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78/ChatFlow?node-id=18-7)、通讯录 19:3、发现 19:4、个人 19:5。当前无可调用 Figma 工具，**远端未修改**，本地 `frontend/artifacts/figma-state.json` 标记 pending-tool-access，不能据本地合同通过宣称远端同步完成。

构建递增为 `0.3.77-debug / 2081`。按固定 runbook 完成源构建、Apktool 2.12.1 重建、build-tools 36.0.0 对齐、固定签名及重解包核验，最后升级 Redmi 现有 `com.liuhetong.mobile.debug`；保留正式包和用户数据。

## 最终验证

- `flutter-full-final.log`：1813 项全部通过；`analyze-final.log`：No issues。HTML 119 项通过。
- 仓库脚本的前半段全部通过，后端 1549 通过 / 37 条现有环境条件跳过。边界检查发现 3 条源码断言仍要求原内联图标/按钮写法；更新为语义图标组件与 appearanceKey 参数后，原样续跑剩余步骤：66 项通过，UI 合同、197 文件 AST、单迁移头/离线迁移、OpenAPI 和 Compose 全通过，`verify-remaining.log` 最终 Verification: PASS。没有重复此前已经通过的后端长测试。
- 最终 APK：`artifacts/2026-09-10/conversation-state-main/delivery-apk/final.apk`，142474066 字节，SHA256 `8bd7b6bc804b07fab4059490d7213aea3b1bfe94803ee296e8eae9d29b273c58`。固定证书 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`；签名后对齐通过；26537 个 smali 类语义一致，338 个原生库/资产条目不变，清单语义一致。Debug kernel 包含 showTopMoreMenu、clearAllUnread，与前版 kernel 哈希不同。
- Redmi Note 7 `cbd0156b`：adb install -r 返回 Success；包管理器显示 0.3.77-debug / 2081；主 Activity 启动 Status: ok、PID存在。启动7900ms仅为Debug冷启动记录，不是未读刷新延迟。未卸载、未清用户数据。
- 发布前再次 fetch；所有本地及远程已提交分支仍为 main 祖先，远程 main 没有待合入提交。分支推送及清理在下一段记录。

## 推送与分支清理结果

功能提交 `2b023e8c` 已成功推送 origin/main，并通过 ls-remote 与本地 SHA 一致核验。随后以原子、预期 SHA 条件删除三个已合并远程分支：codex/ios-compatibility、codex/mobile-parity-20260909、codex/wallet-safety-mi6；未对 main 强制推送或改写历史。

本地删除 codex/integrate-main-20260910、codex/video-menu-redmi-20260910、codex/redmi-polish-20260909。旧 Redmi 工作树在确认干净且原任务空闲后原地 detach，保留目录和历史 APK。本地 codex/wallet-safety-mi6、codex/ios-0353-background 仍承载未提交工作；codex/mobile-parity-20260909 为在途任务仍使用的工作树，保留并移除失效 upstream。未删除工作树、未丢弃未提交改动。远程剩余 main，所有删除分支的已提交历史仍可从 main 到达。
