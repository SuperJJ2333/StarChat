# 朋友圈媒体与房间体验修复、iOS 企业重签候选

## 恢复入口

- 用户本次九项要求：异步朋友圈上传/会话同限制、房间通知及角标即时清除、二态日历、无感续页与旧检索、密钥丢失公告管理、公告关闭持久化、多媒体批量转发/选中背景、视频封面、待企业签名 IPA。
- 授权边界：修复与 iOS 候选构建；用户重签回传后再分发。未授权本轮服务候选发布、Android 发布或 TestFlight 上传。
- 状态：只读调查完成主要路径；新增异步队列/封面行为设计待确认。未实施、未构建、未发布。
- 隔离工作树 C:/Users/Administrator/.codex/worktrees/ios-media-room-followup/StarChat，native 工具创建且注册成功；基线 f433381a14d4549b25001059870857d1bfe57a42。
- [设计](../../superpowers/specs/2026-09-28-ios-media-room-followup-design.md)。批准后编写执行计划并声明编辑文件归属。
- 主目录 1779 项冻结移动输入：1104 完全相同、672 仅 CRLF/LF、3 项只增加空行，缺失 0。具体见非Git baseline-source-comparison.json；不覆盖主目录其他任务修改。
- 负责人：root 负责通知、转发、共享 lease/API 接线、文档/集成/IPA；并行调查分别朋友圈、历史检索、公告，均仅只读。
- 下一步：用户确认新增行为方案及封面取舍后执行。iOS 构建预检继续独立核对，不触发云构建或发布。

## 验收台账

|ID|预期|已确认原因/方案|测试与交付|
|---|---|---|---|
|I01|朋友圈离开发表页后继续、失败可恢复|页面持有 upload/mounted/busy；改账号任务队列|待 red/green|
|I02|会话一致的图片/视频限制|现有朋友圈原视频20MiB直接拒绝，先全读原件|待准备接口联测|
|I03|打开房间清通知、即时刷新角标|缺读状态触发；iOS远端须精确room_id匹配|待两端原生/竞态验证|
|I04|仅本机有消息日可点|unknown可点及远端两探测不能覆盖整月|待本地快照/anchor验证|
|I05|滚动无感续页、旧记录快|按钮与短列表死角；每关键词重新O(N)投影|待10k/100k实验|
|I06|缺旧密钥管理员可清除/更改|确认epoch被无关sync取消；失效引用分类不完整|待权限/E2EE审查|
|I07|已关闭公告重进仍隐藏|真实lease wrapper没有持久scope|待真实接线失败用例|
|I08|批量媒体转发、持续选中背景|元数据误计完整附件内存；仅圆圈选中|待有界调度/幂等用例|
|I09|跨设备朋友圈封面|只有上传者本地poster；远端无封面DTO|等待用户小封面接口/整视频抽帧取舍|
|I10|提供待企业签名IPA|Windows无Xcode；已有GitHub macOS仅构建能力|待修复、冻结、原生门禁与构建|

## 阶段计时

|阶段|开始+08|结束|分类/结果|
|---|---|---|---|
|调查|精确首次工具时间未知|持续中|并行只读；第一个可核实clock00:49:59|
|隔离创建|精确开始未知|00:57前已完成|native create_worktree返回注册成功|
|源码基线比较|00:57:15前|00:57:15|1779路径无缺失；3差异复核仅空行|
|iOS预检|调查并行|持续中|远端workflow较本地新；纯Swift门禁含UIKit问题待修复|

首次精确起点未知；并行区间不简单相加。当前没有新 IPA、Debug 安装、生产服务或更新弹窗变更。用户各问题实际平台/build 尚未提供，不能假设全部来自公开2173或Android2188。

## 证据与交接

证据仅放 docs/verification/artifacts/2026-09-28/ios-media-room-followup。敏感会话、用户消息、密钥与原始媒体不入日志。保留此前全链路性能诊断；attempts 不等于用户数。iOS 预检不能代表 Xcode 或真机通过；拿到最终签名包前不切分发。

## 基线预检

Flutter3.44.9/Dart3.12.2可用，C盘约143GB可用；无.env。隔离工作树依赖首次pub get继承系统镜像域导致lock中三个包补丁版漂移（image_picker_ios、octo_image、permission_handler_apple），首次45项绿色只代表该漂移输入，不复用为固定候选证据。保留漂移lock及真实差异，恢复本任务原lock，显式PUB_HOSTED_URL=https://pub.dev并pub get --enforce-lockfile exit0，固定输入四文件基线45项通过、exit0（baseline-focused-locked.log/json），仅证明基线可运行，不能称新修复已通过。未升级/提交依赖，后续Flutter命令应保持该host及lock约束。iOS只读预检记录位于ios-preflight/report.md，未触发CI或取签名资料。
