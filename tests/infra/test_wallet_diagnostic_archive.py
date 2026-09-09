import json
from scripts.wallet_diagnostic_archive import diagnostic_line


def test_archive_omits_legacy_raw_messages_and_non_schema_data():
    assert diagnostic_line('password=secret') is None
    assert diagnostic_line(json.dumps({'message': 'secret', 'schema_version': 1})) is None
    record = {'schema_version': 1, 'service': 'tron-watch', 'component': 'reader',
              'level': 'ERROR', 'event': 'request_failed', 'reason_code': 'READ_TIMEOUT',
              'password': 'secret', 'body': 'secret'}
    result = diagnostic_line(json.dumps(record))
    assert result['reason_code'] == 'READ_TIMEOUT'
    assert 'secret' not in json.dumps(result)
