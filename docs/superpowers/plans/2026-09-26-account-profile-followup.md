# 个人信息与账号设置反馈实施计划

> For agentic workers: 使用subagent-driven-development，先red/green，规格审查先于质量安全审查。禁止同文件并发编辑。

Goal：热缓存设置子页，修复缺失服务端路由，统一7项个人资料并真实支持365天改畅聊号。
Architecture：会话级API缓存；identity公开改号服务与normalized claims唯一索引；稳定UUID/Matrix域；基于当前生产r4源码做最小发布候选。
Tech Stack：Flutter3.44.9、Python3.12/FastAPI/SQLAlchemy/PostgreSQL、HTML custom elements与现有token。

用户已批准本目录同名设计与新规则。隔离worktree account-profile-followup、branch codex/account-profile-followup、HEAD b9eca8a4；78文件原工作区快照仅作为输入，不覆盖其他任务。生产0088及r4相交变更需先融合。

## 1 Backend owner inspect_profile_identity

Files：新modules/identity/username.py，models.py/registration.py/profile.py，api/profile.py，core/idempotency.py及新migrations/versions/0089_username_claims.py，新tests/business_api/test_username_change*.py。不改api/identity.py或main.py（父代理融合生产）。

- [x] 写并运行缺失改号、cooldown/unique/旧号重注册red，保存真实日志。
- [x] 新claims/时间列、迁移回填、公共in-session idempotency、UsernameService/routes/DTO/限频/审计Outbox，profile masked_phone。
- [x] 格式/冷却边界/并发/幂等/新号登录搜索/Matrix稳定及注册两路径专项green；输出API合同给移动代理。

## 2 Cache owner inspect_account_loading

Files：core/business_api_client.dart，core/account_credentials_gateway.dart，仅新增test/core/account_settings_hot_cache_test.dart及必要core测试。

- [x] 现有method重复GET/singleflight/401刷新/pending锁red。
- [x] 会话epoch隔离TTL5m同步getter，force/单飞/迟到读写保护，GET可信刷新、OTP不变；绑定成功/未知失效。
- [x] TTL/登录登出/可信refresh/迟到结果回归与既有账号/诊断客户端相关green。

## 3 Mobile page owner （父代理分配）

Files：profile_page.dart/profile_controller.dart/account_settings_pages.dart，新username-change页及profile-gateway文件，app_home.dart/Matrix profile_repository.dart/必要matrix_home_page.dart，相关page/controller测试。不得改BusinessApiClient缓存owned文件。

- [x] 七项顺序/右对齐/箭头/缓存重进零spinner/编辑成功失败red。
- [x] 共享注册组件，字段独立编辑、绑定直接入口、真实UsernameGateway与5m缓存展示、保存回页/重启持久。
- [x] 手机/邮箱权威同步，群开关实际邀请行为更新，失效不自动允许；资料/好友缓存保持UUID/Matrix ID。

## 4 Parent frontend/docs/integration

Files：frontend profile/catalog/新username画面组件/styles/tests、UIregistry、设计/ADR/plan/task/OpenAPI、生产相交api/identity.py/phone.py/main.py（先融合后交给backend只编辑自己owned）。

- [x] 注册组件/HTML demo新布局和所有状态；先frontend red再green/UI合同。
- [x] 接收生产源码对比当前r4，三方融合且保留手机号邀请码/0088grapheme修复，隔离PG迁移与恢复。
- [x] 规格/领域独立review→质量安全review，修复实质问题。
- [x] 最终冻结输入，Flutter analyze/完整test、frontend、API/worker适用verify、OpenAPI/迁移单head/compose；复用未变证据。
- [x] 原目录按块集成check，版本候选与别的任务/模拟器重核，不复用已占2181。
- [x] 完整具体发布/安装候选及回退可review后才进入必要发布授权；已有授权不重复问。获授权后最小API/worker切换和未授权401双侧HTTPS。Debug按固定重建/签名，--no-streaming -r保留数据安装。
- [x] 更新证据/计时/索引，区分源码、发布、安装、真实OTP与设备验收。

## 实际执行记录

实现、红绿、领域/规格/安全复审、PG16恢复/online和offline迁移、生产授权/发布、固定签名重建及Debug2182保留数据安装已完成。原始全量失败与专项修复、源身份及复用边界见[验证报告](../../verification/2026-09-27-account-profile-followup.md)。主目录并行regional网络摘要仍是待发布源码，不在本次冻结服务或2182中；回填保留该增量。真实双渠道OTP/iOS/真机不是本轮模拟器验收证据。
