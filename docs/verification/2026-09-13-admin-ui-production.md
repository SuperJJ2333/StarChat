# 后台 UI 与钱包闪窗生产发布

2026-09-13 13:48:41 +08 已发布，13:49 两端验收完成。用户本轮明确批准 demo 发布，并要求已验证进入 USDT 页面根本不出现弹窗。

## 交付范围

| ID | 交付与证据 | 状态 |
| --- | --- | --- |
| U1 | 客服管理/点钻派发字段成组、窄屏单列，沿用已审查 demo | 已发布 |
| U2 | 普通/窗口外补入账的审批、预检和明确确认入口；未知结果禁止跨流程重放 | 已发布 |
| G1 | 等待服务端验证状态时显示页面内 role=status，绝不创建验证 dialog；仍清除并隐藏敏感内容 | 已发布 |
| G2/G3 | 五文件 SHA256、私有备份、失败恢复、HTTPS 两端核对、API 与容器不变 | 通过 |

根因：walletAccessPanel 初始及 focus/lock 调用 show(unknown)，原代码把未知状态也放进 showModal；服务器返回 ready 后再关闭。修复仅新增 unknown 展示分支及非模态等待提示，未改 createWalletAccess、服务端验证、60 分钟期限或业务请求。未验证/过期/网络错误保留现有拦截；不缓存凭据，不自动重放操作。

Astra 亲读实际 diff、admin-home→walletAccessPanel→guarded API/内容销毁调用链、定向测试和浏览器证据。显式 gpt-5.6-terra 的 wallet_flash 执行产品修改，ui_release_prepare 执行发布工具；最多两人、互不改同文件。审查返工包括页面内等待反馈、累计 showModal 断言、替换后异常恢复、并发漂移时继续恢复其他文件，以及真实 error.code 响应形状。

## 实际验证

- Terra 红测试：旧代码延迟 verified 时 dialog 实际为 1、预期 0，exit 1；新增等待提示断言也先 red；最终 wallet access 定向 11/11，exit 0。
- Astra `npm test`（frontend，Node v22.22.2）：207 通过、0 失败、0 跳过，2255.1366ms，exit 0。完整日志 astra-frontend-final.log。
- Astra `.venv/Scripts/python.exe scripts/verify_ui_contract.py`：30 组件、368 页面 PASS，exit 0。当前工作区另有其他任务增加的注册项/测试；未包含进本次五文件发布。
- Astra Python 3.12.10 `test_release_static.py`：8/8，0.794s，exit 0；`test_postcheck_static.py`：3/3，0.001s，exit 0。含中途替换失败、替换后校验失败、未知漂移保留、备份重入和 payload 漂移。
- Astra 真浏览器：修复前 showModal 累计 1、最终无 dialog；修复后两次进入及 focus 重检累计 0，等待提示可见且无敏感内容。wallet-access-browser.html 最终 PASS，覆盖凭据同步清空、过期敏感 DOM 销毁、配置页面不读资金和不重放。
- 上轮 U1/U2 九个已验收文件 hash 全部未变，复用 [UI demo 实测](2026-09-13-admin-ui-followup.md) 的桌面/390px与合成入账流程。
- 此次静态变更不影响后端/Flutter；按变更影响复用既有综合门禁，不重复整个 verify.ps1，不声称当前整个工作区后端/Flutter全量通过。未用生产管理员会话实操、未操作真实资金、未发布 APP。

证据目录：`docs/verification/artifacts/2026-09-13/admin-ui-production/`。manifest.json 冻结所有 before/after SHA256；release-payload.tar.gz SHA256 `40ae82bc50d7ed5e290aacb624965e30390a9581c6a13e8f77fc409fdd3fc6c1`。

## 生产验收与回退

仅替换 `/opt/starchat/frontend/` 下五个清单文件：src/admin-support-panel.js、src/styles/admin-modern.css、src/admin-wallet-repair-dialog.js、src/admin-manual-deposit-case.js、src/admin-wallet-access.js。未发布测试/demo或整个脏工作区。

当前 API 镜像仍 `sha256:119e69710767af56613425341ed7e7920f5f1d9123d3926c8ee0139dd159ce1f`，schema 0066、repairs/grant/owner 已预检；不改数据库、服务配置或容器。服务器 postcheck 验证五个 live/HTTPS hash、no-store、JSON readiness、四项匿名 401 AUTH_REQUIRED、所有容器 ID/image 不变。工作站通过 loopback SOCKS、保留 TLS 校验，五个 HTTPS hash 与健康 JSON 再次通过。API 最近五分钟无新 traceback。

服务器私有目录 `/opt/starchat/releases/admin-ui-20260913/` 权限 0700，backup 与 backup-metadata.json 冻结只读。回退：在该目录运行 `python3 release_static.py rollback --root /opt/starchat/frontend --release /opt/starchat/releases/admin-ui-20260913 --manifest manifest.json`。只恢复已知候选字节，未知漂移拒绝覆盖；无需镜像/数据库回退。首次 prepare 因未传 container IDs 被工具拒绝，尚未修改生产文件；补齐真实 docker IDs 后 prepare/apply/postcheck 均通过。最初下载路径 /tmp 被 SSH helper 路径约束拒绝，改用批准的 /opt/starchat/releases 路径成功。

13:36:36 起已有准确时间记录；13:46 左右最终测试与审查，13:48:41 静态切换，13:49:22 健康/日志验收完成。早期精确起点未采集，不推算总耗时。自己创建的 SOCKS 19013 已关闭；原 HTML demo 服务继续保留。用户刷新后台后生效；真实管理员与真机业务操作由用户验收。
