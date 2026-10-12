# Android 0.4.46+2215 发布工具准备

状态：准备工具待独立 SPEC/domain → QUALITY/security 审查；尚无真实2215 APK、实包门禁、正式package/review批准，未发布。

唯一修改范围为本目录。从已审538f90f6a4efcf5f30a17e1dec462ac01e43c94e的2214框架提取，不改root/mobile/version/全局任务。`adaptation.diff`显示全部旧→新Python差异；新增永久guard测试与离线审计另列。

## 当前只读事实

- HK抓取2026-10-12T11:59:00.230878Z，wrapper退出0：Android0.4.45+2214，iOS0.4.44+2213，minima3/3；schema0095_wallet_source_alerts；35个运行容器身份已逐项冻结；2215文件不存在。源脚本限制docker10/12秒、只读SQL连接3秒/语句5秒，不输出环境秘密。
- 现2214旧包73336097字节，SHA256 `575e24f4c841ed2388311ba19c06e23623838022ed2a438df6c56642436af614`。这只是回退/保留前态，绝非新包身份。
- 永久guard `46d98c6e2d9632b8168d20748b697744d89396852363f259d5eb0d83a7653b9b`；probe `2a6de21ddc26b12bf4b0124365ba20834f821e0ea2d2700fe077f16e96b84a15`。仅哈希，不执行或覆盖。
- SG抓取11:59:27.178466Z，wrapper退出0：CloudFront16规则/Deployed、ETag E3R76HOPU0Z2CB，固定账户/角色/分配/桶策略投影。AWS每调用30秒、外层180秒；无更新命令执行。
- 七个静态文件两份副本保留线上原始字节，`.gitattributes`以opaque保存。所有其他输入身份使用Git blob字节；快照不替代发布时新preflight。

## 变更与保护

目标仅Android0.4.46+2215，原固定75b31签名/com.liuhetong.mobile/arm64-v8a。发布说明为“修复图片和视频发送失败问题，提升媒体发送稳定性。”。两static文件、三Android设置；iOS2213五设置、minima、安装URL、其他五static、其他ABI、旧APK、35容器、schema、永久guard/probe与桶策略保持。

CloudFront只追加一个2215精确HK-origin规则，保留原16条与所有其他字段。仅最终root执行时允许；本轮只读SG。UNKNOWN禁止重放与盲回退；每个mutation单次/前阶段receipt约束、CDN实际HEAD/CORS先于alias/publication、静态CAS和经过原字节校验的回退均沿用。

新增guard/probe在fresh preflight及HK公共写前再哈希，缺失/读取失败/漂移均拒绝。读快照增加独立只读短SQL事务及超时；发布SettingService事务体完全未改。不会恢复/重启服务。`package_release.py`只验证现有最终APK与builder原始receipts，不构建或签名，无签名工具路径依赖。

## 验证及其边界

- `version-red.log`：30例先跑旧版本行为，1FAIL/15ERROR，目标断言2214≠2215及新基线拒绝，非导入缺失；另14例本来通过。
- `version-green.log`：30PASS/6.815s。包括原27项与不可削弱的三项静态回退/原始字节回归。
- `guards-red.log`：2例的5个子断言证明旧代码未检查guard漂移/读取失败；随后`all-boundaries-green.log`32PASS/6.921s。
- `git-export-green.log`：从精确Git index/blob导出全部输入（不用git archive或平台换行转换），32PASS/7.683s；包含新增旧2214/旧0.4.45成品拒绝断言。16个Python AST、两CLI help、14个原始静态捕获校验均PASS。源码与最终导出身份由`preparation-input-identities.json`固定；`verify_preparation.py`本地复验不做网络/数据库操作。
- 原六例真实PostgreSQL证据只复用、不重跑：`postgres-closure.json`证明transact函数UTF-8逐字一致、完整settings模块在仅版本/notes/前态文字归一化后相等；四个依赖Git blob一致，六例测试仅版本/module/trace标签变化。旧API镜像和schema也一致。`reused-postgres-2214.log`是旧6PASS/8.16s，不是本轮PG或生产验证。
- `scripts/verify.ps1`已预检，会写render环境并跑全局server/client套件；本任务无产品变化，不重复root当前共享/native/build门禁。本目录用专用离线32项+PG精确闭包覆盖改变输入，不把替身当远程事务或真APK成功。
- 只读SSH共HK/SG各一次；未运行任何execute_release远程阶段，未上传云/写服务器/起容器/发布设置/业务请求。所有合成APK及模拟批准仅存在unittest临时夹具，结束清理。

## 下一步

1. 非作者按本冻结代码与输入做SPEC/domain，之后QUALITY/security；若通过只表示准备框架可供最终实包审查。
2. root提供2215真实最终APK、artifact.json、原始steps.tsv、mobile-inputs.json，以及shared_flutter/native_android/final_apk三类实际门禁（含真实媒体发送回归）；缺任何一项不得构造成功记录。
3. 按`usage.md`离线创建新package，检查实际staged两static/三settings/CF17/保持项及完整冻结身份，再绑定双审报告和唯一operation_id。未生成任何虚构新APK SHA或批准文件。
4. root授权执行精确包时，runtime前重新只读preflight；若35容器/guard/schema/版本/静态/CF等漂移，停下说明，不能静默重冻或回退旧服务。发布、后验和source两文件回填由root负责，本代理不执行。

证据格式：diff空白上下文及unittest原始子断言行尾空格保留，局部attributes仅关闭这些证据文件的空白诊断；产品/发布Python源码空白检查仍开启。普通输入采用Git LF字节，opaque静态捕获不转换。
