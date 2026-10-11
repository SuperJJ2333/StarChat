"""No handlers/DB/network calls. Run in image's unmodified cwd/import path."""
import hashlib
import json
import os
import main
import worker
import lease_renewal
import app.core.outbox as outbox

assert not os.environ.get('PYTHONPATH'), 'probe must preserve deployed default import path'
assert outbox.__file__ == '/usr/local/lib/python3.12/site-packages/app/core/outbox.py'
assert worker.__file__ == '/opt/business-worker/app/worker.py'
assert main.__file__ == '/opt/business-worker/app/main.py'
assert lease_renewal.__file__ == '/opt/business-worker/app/lease_renewal.py'
assert main.OutboxConsumer is outbox.OutboxConsumer
assert main.Worker is worker.Worker
assert main.create_renewal_engine is lease_renewal.create_renewal_engine
expected = {
    main.__file__: 'f320662c59491b66c2fe9e776c83634c16f5ac780db00d0ecc0d4fd272312494',
    worker.__file__: 'b59f5619156e5ea7c0c43dfc71cd729166b4aa5ee1ed6f7d02cadce1adde7a59',
    lease_renewal.__file__: '37ae78fa6488a81936ff81e5d753b54678edc9047d8552ee665ca8c0726bd4d1',
    outbox.__file__: '8306c0b0c516ab70b3e1b556a3c17ad1053a16d7f92016b4df162ea58f535a12',
    '/opt/business-api/app/core/outbox.py': '8306c0b0c516ab70b3e1b556a3c17ad1053a16d7f92016b4df162ea58f535a12',
}
for path, digest in expected.items():
    with open(path, 'rb') as stream:
        assert hashlib.sha256(stream.read()).hexdigest() == digest, path
consumer = main.OutboxConsumer(None)
renewal_consumer = main.OutboxConsumer(None)
constructed = main.Worker(consumer=consumer, renewal_consumer=renewal_consumer,
                          handlers={}, worker_id='synthetic-probe')
assert constructed._consumer is consumer
assert constructed._renewal_consumer is renewal_consumer
print(json.dumps({'result': 'PASS', 'default_entry_consumer': outbox.__file__,
                  'worker': worker.__file__, 'source_hashes': expected,
                  'handlers_executed': False, 'database_factory': None}))
