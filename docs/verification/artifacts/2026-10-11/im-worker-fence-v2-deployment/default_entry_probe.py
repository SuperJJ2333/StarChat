"""No handlers/DB/network calls. Run in image's unmodified cwd/import path."""
import hashlib
import json
import os
import main
import worker
import app.core.outbox as outbox

assert not os.environ.get('PYTHONPATH'), 'probe must preserve deployed default import path'
assert outbox.__file__ == '/usr/local/lib/python3.12/site-packages/app/core/outbox.py'
assert worker.__file__ == '/opt/business-worker/app/worker.py'
assert main.OutboxConsumer is outbox.OutboxConsumer
assert main.Worker is worker.Worker
expected = {
    worker.__file__: 'f88387d6c957f774b6c137f786b82235b74e8a5cf26a5e282259c7da94eb2299',
    outbox.__file__: 'a2e606116fef84986d7d4781090d792f6d8d6f0785b8679db3299160a660f680',
    '/opt/business-api/app/core/outbox.py': 'a2e606116fef84986d7d4781090d792f6d8d6f0785b8679db3299160a660f680',
}
for path, digest in expected.items():
    with open(path, 'rb') as stream:
        assert hashlib.sha256(stream.read()).hexdigest() == digest, path
consumer = main.OutboxConsumer(None)
constructed = main.Worker(consumer=consumer, handlers={}, worker_id='synthetic-probe')
assert constructed._consumer is consumer
print(json.dumps({'result': 'PASS', 'default_entry_consumer': outbox.__file__,
                  'worker': worker.__file__, 'source_hashes': expected,
                  'handlers_executed': False, 'database_factory': None}))
