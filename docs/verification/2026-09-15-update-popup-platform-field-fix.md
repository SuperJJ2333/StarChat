# 2026-09-15 更新弹窗不显示根因修复（服务端 android 投影缺 platform 字段）

## 现象

0.3.89/2111 正式包客户端不出现 0.3.90/2115 更新弹窗。

## 根因（铁证）

2111 客户端 `latestAppUpdate()` 硬性校验 `response['platform'] == 'android'`，
字段缺失即按“未配置”静默跳过。实测生产容器 `create_app_update_router` 的
android 投影返回体**没有 `platform` 字段**（iOS 投影有），生产镜像的
`app/api/app_update.py`（sha256 `65a806b3…`）落后于仓库版本
（sha256 `04ce507b…`，无条件携带 platform 字段）。

客户端逻辑与服务端设置本身均正常（探针测试 2111 全路径判定 DIALOG；
settings 行 0.3.90/2115 正确）。

## 修复（最小镜像覆盖，遵循 admin-production-workflow）

- 备份：`/opt/starchat/docs/verification/artifacts/2026-09-15/appupdate-platform-fix/app_update.py.before`
  （sha256 `65a806b3…`，0700 目录）。
- 覆盖：仓库 `services/business-api/app/api/app_update.py`（sha256 `04ce507b…`）
  经跳板上传 → 服务端 tmp 哈希核对 → `docker cp` 入容器（容器内 sha256 一致）
  → `docker restart starchat-business-api-1`。
- 验证：容器 healthy；函数级投影断言 android `platform='android'` + latest 2115、
  iOS `platform='ios'` + 2085；未授权 401（android/ios 双平台路由存活）；
  其余 starchat 容器全部未动。

## 客户端影响

- 2111（0.3.89）：冷启动或切回前台（距上次检查 ≥30 分钟）即弹 0.3.90/2115 更新。
- 2089 及更早带 platform 校验的客户端：同样恢复弹窗。
- 该修复同时让未来的 Android 发布不再被此字段缺失静默拦截。

## 相关客户端修复（同日，commit ab50f4e9）

`compareVersions` 剥离 `-debug` 等预发布后缀——此前 debug 包（versionName 形如
`0.3.89-debug`）语义比较失效、错误回退构建号比较。

## 未覆盖

- iOS OTA（0.3.90 待签 IPA）仍待企业签名回传，独立事务。
