# 群二维码与好友流程交付记录

## 已交付

- 线上 `business-api`：`starchat-business-api:qr-friends-20260905-93f61cd05762`，健康状态 healthy。
- 线上数据库从 0035 升至 `0036_group_join_tokens`；只部署本次 8 个相关文件，未包含本地 0037 钱包迁移或其他金融修改。
- 二维码令牌接口上线；私密群以当前管理员身份邀请后加入，保留封禁/成员/管理员权限校验。修复签发重放、兑换与审批失败重试、撤销幂等冲突。
- 好友请求区分 INCOMING/OUTGOING，保留原始招呼；备注、标签、朋友圈权限写到申请人自己的联系人设置。双向朋友圈隐藏规则生效。
- 客户端按钮文字居中，默认招呼使用本人用户名，朋友圈权限改为默认允许及两个独立开关/仅聊天，通讯录与新的朋友显示红点，共用现有消息通知类别。
- 接受申请后打开规范私聊；原申请者在线轮询时使用本人 Matrix 会话发送加密招呼，稳定 transaction ID + 账户本地标记处理重试。仅本版已提交/观察到待处理状态的申请会自动发送，防止历史招呼批量补发。
- 最终 debug APK 已覆盖安装到 MI 6 `cbd0156b`，安装返回 Success，版本 0.3.36 / 2039，最后更新时间 2026-09-05 15:27:10；应用已启动。未卸载、清数据或用 adb 强授权限。

## 验证

- 线上源代码基底 + 本次 overlay：群/好友/朋友圈 **72 passed**；最终 gateway **7 passed**。
- 全仓脚本：Business API/Worker **336 passed, 19 skipped**；其前序仓库、部署、模板、渲染、基础设施、推送桥、Matrix Bot 检查通过。
- Flutter contacts/friendship **40 passed**，按钮几何检查 **6 passed**；最终 app_home 静态分析无问题。
- 最终移动端边界检查 **47 passed, 4 failed**。这四项是前轮已在原始 HEAD 复现的通话源码字符串检查：compact video Expanded、旧 openIncomingCall/rejectIncomingCall 接口、旧 Flutter native-call 事件装配。没有修改测试掩盖失败，全仓门禁不能记为全绿。
- OpenAPI 一致性通过；UI 契约 **17 components / 330 screens** 通过；Alembic 单 head 和离线 SQL 检查通过；Compose render 通过。
- 线上容器健康、正确发布镜像和迁移版本确认；内网/公网 health 200；好友列表及二维码签发未登录请求均为 401。
- APK 从源码构建，standard、ARM64、debug、无 Dart 混淆/加壳。签名 SHA256 `34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1`。
- 最终 APK SHA256：`4B4D5BB0F4BC7DA945198ABA6443D9B9E3BF61AFBF76F9E184885F8FB880558A`。

## 生产维护与回滚

发布目录 `/opt/starchat/releases/qr-friends-20260905-93f61cd05762/` 保存 manifest、源码备份、数据库归档、部署脚本和 SUCCESS.json。数据库备份留在服务器，权限 600，归档目录可读检查通过；未执行完整恢复演练。

本次创建持久化 `/opt/starchat/docker-compose.feature-release.yml` 来固定镜像。后续管理此服务时使用：

```sh
docker compose -p starchat --project-directory /opt/starchat \
  -f /opt/starchat/docker-compose.yml \
  -f /opt/starchat/docker-compose.production.yml \
  -f /opt/starchat/docker-compose.feature-release.yml \
  up -d --no-deps --no-build business-api
```

回滚时将该 override 的 image 改为 `starchat-business-api:before-qr-friends-20260905-93f61cd05762`，执行上述命令并验证镜像/健康，恢复 source-before.tar.gz 中原有源码文件。保留已新增的 0036 表，不运行删除表的 downgrade。后续新发布须更新固定镜像与源码，不能只执行 build 后仍复用旧 override。

## 验收边界

未向真实第三方账户发申请或聊天消息；双人扫码和好友验收留给用户在 MI 6 操作。五秒好友轮询依赖 Flutter 进程存活，强制结束应用后的提醒仍取决于推送链路，本次未证明该场景可达。声音与弹窗受系统通知权限/渠道设置约束。不同发送设备同时在线时，没有跨设备原子去重保证；本地待发标记写入失败且对方极速接受时可能漏掉自动招呼。历史错误归属的联系人权限数据没有批量改写。Figma 按用户此前授权暂缓同步。

详细日志、脚本与 APK：`docs/verification/artifacts/2026-09-05/friendship-deploy/`。代码未提交；保留其他任务的已有修改。
