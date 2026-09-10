# 双平台独立更新与2085交付 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 发布包含已修复聊天逻辑及统计助手的Android更新，交付同源iOS IPA供用户企业签名；平台发布配置、弹窗和关于页下载地址彼此独立。

**Architecture:** 沿用已存在的Android `app_*` 与iOS `app_ios_*` 设置，业务API权威投影；新版客户端显式请求并验证所属平台，自动弹窗与手动检查共用同一投影。本轮只准备两端候选包，先交付IPA；企业签名回传并通过身份/内容检查后，再安排双端过渡发布。旧无平台请求须先核实历史二进制/源码，不以UA或设备名称猜测系统。

**Tech Stack:** Flutter/Dart、FastAPI/SQLAlchemy settings、GitHub Actions/Xcode、Android source+Apktool2.12.1/build-tools36.0.0、Nginx。

授权范围：用户本轮明确要求实现双平台隔离、打包并发布Android更新弹窗、产出iOS候选包及统计助手同步，并再次要求“请你继续”。沿用既有产品设计与2084已验证修复；不新增金融/鉴权规则、不发布未回传的企业包。

隔离工作区 `.worktrees/platform-release-2085`，分支 `codex/platform-release-2085`，起点63900562；最终集成main。临时证据仅 `docs/verification/artifacts/2026-09-10/platform-release-2085/`。不覆盖并行后台任务。

## 验收台账

2026-09-10 用户明确选择：先交付 IPA，企业签名回传后再安排双端过渡发布。本轮准备和验证 Android 包及双端代码，但不切换生产 API、下载页或更新设置。旧 2073 无平台请求不能安全区分双端，过渡发布时仍需明确处理；不得以延后发布冒充旧客户端隔离已经完成。当前所有文件由 root 接手，原分派代理未执行修改。

| ID | 预期 | 实现/验证责任 |
|---|---|---|
| U01 | Android/iOS版本、build、minimum、notes、URL单独读取和发布 | backend agent，settings/API隔离与并发批次测试 |
| U02 | 自动弹窗拒绝跨平台投影，使用对应下载地址 | root，Dart请求/解析/点击测试 |
| U03 | 设置→关于畅聊→版本更新使用相同平台通道 | root，手动入口回归 |
| U04 | Android源码构建→常规重建→固定发行签名→校验→上传→更新弹窗 | root，SHA/签名/包标识/静态页面/API投影/回滚证据 |
| U05 | iOS同源IPA包含语音/账号修复，交用户企业签名，回传前不改iOS发布状态 | root，完整编译/原生CI/包内身份及资产SHA |
| U06 | 两端统计助手均包含最新已确认源 | statistics agent审计，root包内SHA验证 |
| U07 | 保留2084语音、账号存储、单设备登录及视频修复 | root，相关已通过测试复用和受影响回归；iPhone实机仍待企业覆盖升级 |
| U08 | 旧客户端兼容不误投平台 | backend agent调查旧2073/2077请求；发布前明确可识别范围和缺口 |

## 执行步骤

- [ ] backend只读确认本地/生产 `app/api/app_update.py`、`modules/settings/service.py` 差异及旧客户端平台来源。
- [ ] root先写失败测试：双端显式query、平台marker缺失/错配拒绝、下载字段及两个入口一致。
- [ ] backend先写失败测试，再以最小additive改动补平台marker/中性下载字段，保留兼容wire字段和原Android默认行为；不扩大鉴权权限。修改API契约和专项测试。
- [ ] root实现 `core/business_api_client.dart`、`features/update/app_update.dart`、`app_update_dialog.dart` 的必要变更；关于页仅有被测试证明需要时修改。版本递增0.3.81/2085。
- [ ] statistics审计最新HTML与页面加载方式，明确源SHA与现有回归。无需修改已正确逻辑。
- [ ] 先迁移heads/接口漂移/导入，后相关Flutter、Python和完整verify；按修改范围增量复测，规格审查后独立Q/S。
- [ ] 后续签名回传阶段：重新核实并行任务的最新生产基线，按admin-production-workflow精确增量部署API。旧平台兼容事实不清楚时不得声称已解决所有旧版本。
- [ ] Android正式ARM64构建并按android-apk-rebuild签名重建；两端包内统计HTML字节与源码比对；核验iOS原生语音/存储与完整插件编译。
- [ ] 后续签名回传阶段：Android上传不可变版本文件，平台专属下载页/链接更新；分平台设置事务与审计，验证另一平台未串用。发布前后SHA与公网双侧检查，保留回滚。
- [ ] iOS IPA交用户企业签名，记录候选SHA/版本/bundle；回传前不动iOS manifest/弹窗。最终按U01-U08逐项报告实际证据与剩余真机项目。

## 文件所有权

- root：Flutter客户端更新相关文件/测试、版本、打包CI必要调整、下载页面与发布runbook/报告。
- backend agent：`services/business-api/app/api/app_update.py`、必要settings模块、`tests/business_api/test_app_update_settings.py`、对应OpenAPI契约。暂不改`app/main.py`或生产服务。
- statistics agent：审计证据；发现遗漏先报root再领取具体文件。

## 兼容与回退约束

保留现有最低支持版本，不擅自强制升级。App Store签名候选不能冒充企业覆盖包。保留当前API/worker/Synapse的broker运行基线，后续新后台发布可能改变API镜像，部署必须重读而非继承2084旧摘要。任何设置发布必须原子批量写入并验证另一平台完全未改；不删除旧包，不重签成另一身份。无法识别的旧平台请求不能依据不可靠线索杜撰分类。
