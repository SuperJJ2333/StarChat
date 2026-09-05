from pathlib import Path

p = Path('tests/mobile/test_native_call_service_layer.py')
raw = p.read_text(encoding='utf-8')
# 旧组件名 → 新 Telecom 组件名
raw = raw.replace('assert ".call.ChatFlowConnectionService" in raw',
                  'assert ".call.CallConnectionService" in raw', 1)
raw = raw.replace('assert ".call.ChatFlowConnectionService" in manifest',
                  'assert ".call.CallConnectionService" in manifest', 1)
# §四断言：resume 块锚（app_home 中 resumed 判断的实际形态）
raw = raw.replace(
    'resume_idx = home.find("AppLifecycleState.resumed {")',
    'resume_idx = home.find("state == AppLifecycleState.resumed")', 1)
p.write_text(raw, encoding='utf-8', newline='')
print('OK')
