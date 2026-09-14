# 六项财务修改实装审计

日期：2026-09-13。范围：核对用户提供的 7afbc985 / debug 2104 完成报告。只读检查源码、部署、设备身份并运行现有定向测试；没有修改产品、发送真实转账、部署或安装 APK。

## 结论

不能认定六项全部完成。金额/状态行、日期按钮、红包人数默认空白已有代码；名称后缀和群转账存在明确缺陷；账单详情仍是 HTML demo；非好友 Matrix 头像仍未显示。

| 项目 | 实装情况 | 证据与缺口 |
| --- | --- | --- |
| 1 金额靠右及状态 | 代码已实现 | ledger_pages.dart:295–322 右对齐金额/状态列，361–382 状态映射；未作真机视觉验收 |
| 2 日期按钮 | 代码已实现 | ledger_pages.dart 的 _dateButton 为圆角图标按钮，日期选择调用 WeChatDatePicker.show；既有日期交互测试通过，样式/2 倍字体未独立验收 |
| 3 账单名称后缀 | 不完整，有确定缺陷 | LedgerListPage 的所有实际入口未传 identityCache；ledger_pages.dart:339/342/345/355 将 $peer 转义为字面量，即使传入缓存也不会插值。非好友资料补全也未实现 |
| 4 账单详情 | 仅 demo，未实装 | ledger-detail-redesign-demo.html 有 hero、分类图标、大金额、状态等设计；LedgerDetailPage._detail 仍是简单字段列表，没有对应布局和对方信息 |
| 5 群转账范围 | 部分实现，有业务风险 | room_page.dart:2012 把 participant.id（Matrix ID）放进业务 userId；选择后经 controller、gateway、ChatPaymentIntent 原样发送 receiver_id，未解析业务 ID。服务端字段最长 36，收款权限按业务用户 ID 比较。长 Matrix ID 会校验失败，较短 ID 也无法匹配收款人业务身份。chat_transfer_sheet.dart:194 在 roomMembers 为空时仍回退全部通讯录 |
| 6 红包人数及头像 | 人数已改；头像未完整修复 | shares 控制器默认空，群普通/手气红包空值校验为 0 并阻止提交；chat_red_packet_sheet.dart:256–263 丢弃 mxc://，非好友仅回退字母，并非正常展示自定义头像 |

群转账问题以上述调用链为依据，未在生产发起资金操作。应先将 Matrix 成员解析为业务收款人，解析失败禁止提交；群成员未加载时不得回退全部好友。

## 交付身份核验

- 当前 HEAD：c5cd589c799c52557c469d4a225c721292b1fdcd；包含 7afbc9856fd4406d00acdffe4ef7de6bc93c58d9。
- 本地 origin/main 指向 c5cd589c，包含 7afbc985；本次 git ls-remote 因 schannel TLS 握手失败，未独立确认远端实时状态。
- Mi 6 当前已安装 versionCode=2105、versionName=0.3.87-debug，lastUpdateTime=2026-09-13 04:59:13；不是报告所称的当前 2104。仅设备版本查询不能证明每项功能的运行表现，本次未做真机功能测试。
- 经既有 SSH 跳板读取，starchat-business-api-1 健康，镜像 sha256:eb14b5969f5a6953c17ef0186c99e195fbec606241172bc4c370edaa15137038。
- 容器内 /opt/business-api/app/modules/ledger/statements.py SHA256：fd040c99f9cf0a570507382e7381ae228a43c2a783ea97811a4bd42897e6ab02。
- 容器内 /opt/business-api/app/api/ledger.py SHA256：b7d0d336b4e2dc2a2b3f27c08c7adb1dbf703edaca7a3953b24778b71e4fc9bb。
- 两个容器文件均与当前源码完全一致，确认账单对手方投影已部署，且包含后续 ORM 属性访问修复。容器健康不等于真实账单功能已验收。

## 自动化验证

明确指定 gpt-5.6-terra 执行三份现有 Flutter 测试；主代理检查输出与实际调用链。

在 apps/mobile_flutter 执行：

```text
C:\src\flutter\bin\flutter.bat test --no-pub --reporter expanded test/features/ledger/ledger_pages_test.dart test/features/transfer/chat_transfer_sheet_test.dart test/features/matrix/chat_red_packet_sheet_test.dart
```

结果：24 passed，退出码 0。日志和逐项覆盖说明见 [证据目录](artifacts/2026-09-13/finance-six-audit/summary.md)。测试没有覆盖新名称后缀、roomMembers 新分支、头像策略与新详情布局；不能据此称六项全部验收通过。未复跑报告所述 35 项服务端与客户端组合，不能为其历史执行结果背书。

## 后续修复与验收顺序

1. 群转账 Matrix→业务身份解析及成员列表空态禁止回退；覆盖好友/非好友、未加载成员、不同 ID 长度，验证提交业务 ID、收款权限及幂等不变。
2. 修正名称插值并接入所有入口的身份缓存，覆盖备注→昵称→畅聊号和非好友；异步资料到达时刷新。
3. 将账单详情 demo 实装到 Flutter，核对金额、状态、对方信息、账单复制与导航。
4. 为非好友 mxc:// 头像接入现有 Matrix 头像加载组件；覆盖 HTTP、MXC、加载失败和缓存命中。
5. 增补新分支测试后，以唯一构建号和 APK 哈希记录安装身份，再由用户真机验收。

当前工作区有其他任务的未提交修改，本次未覆盖、回退或提交这些改动。
