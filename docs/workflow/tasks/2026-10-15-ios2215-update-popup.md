# iOS2215普通更新弹窗

用户2026-10-15明确要求“请你推送iOS的更新弹窗”，覆盖此前暂不启用弹窗限制；保持精确指定回签IPA SHA4087d408f5e294fe2482a6ccebef65bc0aeb73123cab25fb5a4547ad8ebd7aba，不改变已披露签名/真实APNs/覆盖安装缺口。

本任务拥有本记录、current-state索引和artifacts/2026-10-15/ios2215-popup，复用既有发布器，只替换本次版本/身份/前态/trace参数；无产品或业务代码修改。

方案：读取已发布静态receipt，复核文件完整SHA/三静态SHA/公网HEAD及XML；在发布锁内十键事务CAS仅更新app_ios_latest_version=0.4.46、app_ios_latest_build=2215。最低支持3、notes、安装页、Android五键保持。每个设置经SettingService生成审计；后验实际双端/legacy route投影和两条审计。异常不盲重放，备份0700。

preflight真实PASS。本地相关82PASS/19SKIP：隔离PG测试因本地Docker/固定PostgreSQL16.9依赖不可用跳过，不宣称全量门禁通过。源共享helper hash571153…d3b7da与已验证发布输入一致。执行apply/后验待完成。
完成：2026-10-15 22:03:48+08 IOS_POPUP_PUBLISH_PASS；22:03:51+08 ROUTE_AND_AUDIT_READBACK_PASS。仅iOS latest版本0.4.44→0.4.46/build2213→2215；两条settings.update/SUCCESS审计，trace ios2215-popup-20261015-4087d408。实际iOS/Android/legacy路由投影及十键回读匹配；Android/min3/notes/url、公开三静态、IPA SHA及容器身份保持。独立规格→质量审查通过。服务端HTTPS门禁通过，工作站业务域HTTPS直连未授权检查返回401，鉴权保持。

0700备份/opt/starchat/docs/verification/artifacts/2026-10-15/ios2215-popup-4087d408；阶段前精确起始时间未知。receipt/publish/route-audit证据在ios2215-popup目录。未向用户发APNs、不强制升级；用户手机弹窗及安装结果待反馈。遇问题先读取当前设置和trace再作有审计纠正，不重复apply。无业务代码/移动源码修改，不重复构建。
