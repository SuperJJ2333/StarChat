# 钱包缓存/记录验证

日期2026-09-23，Windows / pwsh7，Dart 3.12.2，Flutter入口 `C:/src/flutter/bin/flutter.bat`。候选root统一准备pub环境；输入SHA256（含pubspec.lock）见[清单](artifacts/2026-09-23/wallet-input-hashes.json)。基线e8bf1440；共享工作树其它任务改动不属本报告。

## 设计与安全

- 复用WalletEntryStore、WalletEntrySnapshotStores；新资源key为 `<origin>:<subject>/read/recharges|fx|history`，运行态再附epoch。快照只白名单落展示字段，金额维持十进制字符串，凭据/未知API字段不落盘。
- 磁盘快照冷启动先展示且一定刷新；成功内存快照30秒内再进入免重复请求；显式刷新、交易前余额刷新不受窗口限制。失败保留数据并提供重试。
- 充值本地状态未获得本会话成功核验前标记旧数据，收款二维码与付款地址复制不开放。FX旧值标记stale，不能伪称最新汇率；交易仍走原后端报价/鉴权/幂等接口。
- 提现申请卡在任何网络等待之前恢复。余额刷新失败保留展示，但依赖fresh余额的写入准备失败关闭。
- store忽略跨epoch晚到成功/失败；wallet主gateway锚定初始化scope；history同State更换client/scope/epoch重新取store；bootstrap监听注册及网络进入前后验证mounted/epoch。退出沿用现有disposeAll清理，不增加账号外共享缓存。

## 验证结果

| 检查 | 命令/结果 |
| --- | --- |
| 红：epoch晚到数据 | `flutter test --no-pub test/features/finance/wallet_entry_state_test.dart --plain-name "in-flight result from an ended account is never cached"`，exit1，hasData true与预期false不符 |
| 红：完全离线提现卡 | `flutter test --no-pub test/features/wallet/manual_wallet_payout_status_cache_test.dart --plain-name "断网冷启动"`，exit1，本地状态卡未渲染 |
| 红：HTML复用 | `node --test frontend/tests/wallet-cache-history.test.mjs`，exit1，未找到ledger row |
| 红：同State切账号 | `flutter test --no-pub test/features/wallet/wallet_read_cache_test.dart`，exit1，Bob页面残留1个Alice LedgerRecordRow |
| 钱包/进入态/账单专项 | `flutter test --no-pub test/features/wallet test/features/finance/wallet_entry_state_test.dart test/features/ledger/ledger_pages_test.dart`，166通过/0失败，exit0，[日志](artifacts/2026-09-23/wallet-tests-final.log) |
| 最后安全补丁覆盖 | `flutter test --no-pub test/features/wallet/wallet_read_cache_test.dart test/features/wallet/wallet_entry_cache_test.dart test/features/wallet/manual_wallet_payout_status_cache_test.dart`，13通过/exit0。含同client同scope epoch重登更新金额、无Key账号切换、缓存→失败→重试成功、旧QR不显示 |
| Analyzer | `dart analyze lib/features/wallet lib/features/finance/wallet_entry_store.dart lib/features/ledger/ledger_pages.dart test/features/wallet/wallet_read_cache_test.dart test/features/wallet/manual_wallet_payout_status_cache_test.dart test/features/finance/wallet_entry_state_test.dart`，No issues found，exit0，20:32 +08 |
| HTML | 最终钱包视觉补丁后全前端298通过/0失败/exit0，见[日志](artifacts/2026-09-23/wallet-frontend-final.log) |
| 独立审查 | transfer_restore先规格后安全复核，报告的scope替换/epoch采样/async bootstrap监听/State闭包/时间格式问题均关闭；审查者22项定向通过 |

## UI交付

Flutter：manual_wallet_page、wallet_history_page，ledger_pages抽取LedgerRecordRow/formatLedgerShortTime。HTML：`frontend/index.html`目录screen id `wallet-history-all`、`wallet-home-default`、`wallet-deposit-address`、`wallet-withdrawal-default`（wallet-demo均带“模拟离线”/“重试更新”）。root维护共享 `ui-contract` registry；现有demo通过按钮模拟cached-offline，无新增catalog条目；契约与集成门禁由root统一记录。

记录页使用共享账单行，Flutter最近50条/本地筛选的有限范围明确可见；目前没有新增向后分页功能。HTML wallet-only variant横向分段、彩色图标、日期不重复状态。Figma 已退役：本次变更仅更新 HTML demo（frontend/index.html）。

本报告不宣称已安装/真机通过/生产发布；最终全量、verify、包版本/签名/设备证据以root集成交付记录为准。

root首轮全Flutter于20:28启动，20:29安全补丁与随后新epoch用例落地后出现line111的40USDT断言失败，属于混合编译输入嫌疑，不能声称该轮通过。固定最终输入单独重现4项全部通过/exit0（[日志](artifacts/2026-09-23/wallet-fixed-input-repeat.log)）；root安排冻结源码全量重跑确认，不为该混合轮盲目改写业务实现或削弱断言。

生命周期边界：当前main.dart只创建一个BusinessApiClient，登录切换通过scope/epoch隔离。不同client实例但同scope与同epoch仍会共用旧gateway；本轮不宣称支持任意多client注入，后续若引入需将实例身份加入缓存键或失效旧实例。

## FX刷新最后增量

首次FX失败、恢复网络后点击刷新原先仍fxCalls=1，新增红用例预期2；修复只在显式刷新时强制本地Store.refresh，初进入仍30秒缓存优先。相关17通过、root整个钱包/进入态/账单167通过，独立复审确认服务端3600秒TTL/金融写权限不变。新用例随后刷新8.00、估算160.00可见，未降低断言。
