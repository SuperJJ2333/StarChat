# 2026-09-23 完整门禁测试收集时钟修复

来源：root完整verify仍在运行，测试模块收集后超过JWT有效期，Matrix/Profile API正例取得收集时刻签发的过期JWT。仅改测试夹具，不改TokenService或产品过期规则。工作树support-feedback-20260923，基础7140ace2。

## 红绿证据

- test_matrix_login_token.py新增test_access_token_fixture_uses_issuance_time_after_slow_collection，将模块NOW设为实际时间前1小时。修前exit1，TokenService.decode_access_token明确ACCESS_TOKEN_INVALID / outside its validity window；修后_access_token仅签发时钟改datetime.now(timezone.utc)，其他用户/网关固定NOW保持。matrix_login_token+matrix_login_broker：35 passed in9.84s，exit0。
- test_profile_api.py新增test_profile_token_fixture_uses_current_time_after_slow_collection，同样NOW前1小时，修前exit1 ACCESS_TOKEN_INVALID。_add_user只将TokenService签发clock改当下，用户资料日期NOW保持。最终matrix_login_token+matrix_login_broker+profile_api：49 passed in71.60s，exit0。
- 只读AST扫描tests/business_api内引用TokenService/jwt.encode的模块级datetime.now/utcnow/time.time赋值，另发现admin/test_caibi_grant_errors.py的FRESH。JWT已当下签发，但reserve observed_at默认参数在收集时冻结。
- 新增test_fresh_reserve_fixture_survives_slow_test_collection：runpy仅重新载入本测试模块，载入期间模拟datetime.now为1小时前，随后恢复运行时钟并走真实ASGI财务接口。修前exit1，目标201实际422 RESERVE_EVIDENCE_STALE。修后build_app observed_at默认None，在构造时使用now；显式过期测试保留运行时now−10min。整个文件7 passed in36.81s，exit0。

所有测试命令为py -3.12 -m pytest <对应文件/节点> -q --tb=short，PYTHONPATH=services/business-api;.，PowerShell7 UTF8和PYTHONUTF8/PYTHONIOENCODING已设置。diff --check三文件exit0。文件SHA见artifacts/2026-09-23/support-feedback/payout/collection-clock-inputs.json。

扫描其余NOW匹配主要为合法固定领域/网关时钟，未全局替换。上述测试在根完整verify另一进程旁独立运行；根原进程已加载旧测试模块，不把新证据冒充原运行通过。无生产资金请求/迁移/发布/签名操作，无产品源码变化。
