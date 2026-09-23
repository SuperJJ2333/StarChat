# 2026-09-23 红包与充值 UI 验证

用户要求已在 Flutter 实现，尚未构建或安装。主协调任务负责最终候选；本子任务未运行全仓 verify.ps1，避免与集成门禁重复。

## 改动与验收

1. ChatRedPacketSheet 移除静态手续费/限额/人数说明，退款句固定在可滚动内容下方。业务限额刷新、手续费余额校验、服务端错误弹窗及失败重发保持。退款句 widget 测试验证底部位置。
2. ManualWalletPage 的充值订单二维码居中，下方复用图标按钮并接入既有 WalletQrExporter。生产实现仍通过 ensureGallerySaveAccess、QR PNG 渲染与 PhotoManager.editor.saveImage 写系统相册。测试覆盖实际订单地址传递、异步保存成功、权限拒绝反馈；旧充值 QR 及生产导出器回归通过。
3. 标签为“收款地址”，压缩展示字符串右对齐、复制仍使用完整值。没有变更金融状态/算法/API/权限。

HTML: `frontend/index.html?screen=redpacket-create-direct-equal&capture=1`；`frontend/index.html?screen=recharge-directory-directory&capture=1` 点“下一步”。充值 demo 复用已存在的下载页二维码作为明确标注的演示样例，下载链接会下载该样例；生产二维码始终来自业务订单。Figma 已退役：本次变更仅更新 HTML demo。Registry 为 packages/ui-contracts/changliao-component-registry.json，复用既有组件与 tokens，无新增 token。HTML 节点与交互测试通过；未做浏览器截图视觉验收，需 root/真机复验。

## 命令与结果

运行环境 Windows、PowerShell 7 UTF-8，Flutter 3.44.9 / Dart 3.12.2。工作区基线 HEAD `1baaf36eaa02f4ee903f09591b694cac1a90695b`，包含他人未提交改动，未覆盖。

在 apps/mobile_flutter：
- `C:/src/flutter/bin/flutter.bat test test/features/matrix/chat_red_packet_sheet_test.dart --plain-name "send page shows wechat-style" --reporter compact`：exit 1，旧手续费提示仍在，预期红证据 `artifacts/2026-09-23/wallet-ui/red.log`。
- `C:/src/flutter/bin/flutter.bat test test/features/matrix/chat_red_packet_sheet_test.dart test/features/wallet/support_order_workflow_test.dart test/features/wallet/wallet_qr_export_test.dart test/features/wallet/wallet_official_deposit_test.dart --reporter expanded`：exit 0，38 passed，`green.log`。
- `C:/src/flutter/bin/flutter.bat analyze`：exit 0，No issues found，`analyze.log`。
- frontend `npm test`：exit 0，281 passed，`frontend.log`。
- root `python scripts/verify_ui_contract.py`：exit 0，32 components/398 screens，`contract.log`。

迭代中出现一次测试等待未完成保存导致 pumpAndSettle timeout，一次漏 pump 后按钮未滚入视口，修正测试时序；误写 wallet_qr_exporter_test 文件名已纠正为实际 wallet_qr_export_test。均非产品失败，最终日志完整通过。初次 shell cwd 路径错误未形成有效红证据；以上 red.log 才是有效记录。前端无 package-lock.json，不宣称锁文件存在。

SHA256：
- chat_red_packet_sheet.dart: 885E208AD5F50BD3E81657A489708FD5CBFAEB43FC86164C870AFF4B8563EE42
- manual_wallet_page.dart: 2B56BC3AAF59D06CE17B5462DB787747EA1C962D0FCE6998BAA93D7A5ADDAED1
- pubspec.lock: 244FFFFC0062B22FF307CA2BDD91F5AB493740117898C807F39658C5560C7028

规格自审先于质量自审：3 项请求与 widget/HTML节点结果吻合；质量自审确认只有展示与既有保存入口变化，原金融校验和权限调用保留，无钱包地址或秘密硬编码到生产。完整独立审查、冻结候选门禁与真机仍归 root。

## HTML browser review follow-up

通过 cua 独立临时 Edge 标签检查 root 的 candidate 本地服务 8155，未操作 root 工作台标签。
- 红包 `?screen=redpacket-create-direct-equal&capture=1`：可访问树仅含退款静态说明；DOM 实测说明 top823/bottom840，父内容 bottom852（393px 设备画布），距底12px。默认740px浏览器视口截断画布，不能据此声称页面溢出。
- 充值 `?screen=recharge-directory-directory&capture=1` → 下一步：QR居中，保存箭头居中在其下，无原二维码下方提示。保存链接明确下载既有demo QR资产。
- 发现 HTML demo 地址行复制动作仍带“复制地址”文字，窄画布中竖排挤压地址。已通知 root，仅demo有此缺陷；Flutter用现有无文字copyIcon，专项通过。冻结构建期间未修改源码，等待root决定HTML单独修正。
- 一次fullPage截图CDP超时，普通截图与DOM几何读取成功，不冒称有持久截图文件。

### HTML 修正与最终复验

root 随后授权仅 HTML 修复：main 和 .worktrees/staff-workbench-ui-20260923 的 phone-flows.js 已统一为复用 icon("copy") 的 aria-label 按钮，48×48px、不收缩、地址单行靠右。误先同步 staff-debug-2163 同文件，不涉及任何 Flutter 源码或构建输入。三处 phone-flows.js SHA256 均为 6DBD23F9734BB968AC6C5B5899ED3FF14087D7861060514C82D7C455CA4BA7E9。

main frontend npm test exit0，281通过（frontend-visual-fix.log）；UI contract再次exit0，32组件/398屏。main phone-flows.test.mjs补充48px纯图标断言与SVG DOM harness。

8155实际候选刷新后普通浏览器截图复验通过：复制图标横向独立显示，地址单行靠右、长演示值省略，无竖排；二维码和下方保存箭头居中，没有二维码下提示文字。未改root工作台标签，临时标签关闭。Flutter源码保持冻结。

后续交付状态：本批已完成生产发布及Mi6 2163安装，上文未发布/未安装为实现阶段记录；以[最终发布记录](2026-09-23-staff-direct-release.md)为准。
