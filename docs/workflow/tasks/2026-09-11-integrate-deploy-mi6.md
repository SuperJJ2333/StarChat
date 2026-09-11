# main 集成、跳板部署与 Mi 6 Debug

## 恢复入口

- 用户授权：合并其余分支到main、push、跳板部署生产、Debug覆盖安装Mi6；用户自测。2026-09-11本轮授权取代先前任务的禁止发布范围。
- 计划：../../superpowers/plans/2026-09-11-integrate-deploy-mi6.md。
- 角色：Astra主审；既有显式gpt-5.6-terra执行者profile分支审计、viewer设备/签名预检。文件所有权先只读，后逐批声明。
- 开始：2026-09-11约22:05+08:00，精确首工具时间未另记录。
- 状态：预检；main=bb51f853，performance=a07c996a且finance未提交。main有用户文档整理及锁文件改动，禁止直接覆盖。
- 下一步：提交已审finance清单，建立整合候选，保护main本地改动，核对所有分支与线上实际来源。
- 证据：主工作区 docs/verification/artifacts/2026-09-11/integrate-deploy-mi6/；finance原证据保留在performance工作树。

## 生产初读

2026-09-11T14:07:38Z，经 scripts/starchat-server.ps1 / jumper 成功：API镜像fea5b9417e5c、worker7e0e9ffc64c6、synapse与sync worker fd9d961a472a；均healthy。后续取完整digest、Compose层和schema再冻结，不能凭此短ID直接覆盖。
