"""Read-only identities + AST-only switch replay; never imports deploy top level."""
import ast
import hashlib
import io
import json
from pathlib import Path
import subprocess
from types import SimpleNamespace

ROOT = Path('C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat')
SOURCE = ROOT / 'docs/verification/artifacts/2026-10-11/im-worker-fence-v2-deployment'
HASHES = {
    'prepare.py': '3b2dde8b075154c761cb3180556e9927bb9fad2adc0528ef53659c76b7ac98b5',
    'deploy.py': '1dd4023f4f63fedf2c1080013e5535838a3afda95330a58cbe4cc01f5906ea73',
}
trees = {}
for filename, expected in HASHES.items():
    raw = (SOURCE / filename).read_bytes()
    assert hashlib.sha256(raw).hexdigest() == expected
    trees[filename] = ast.parse(raw.decode('utf-8-sig'))
specs_node = next(n for n in trees['prepare.py'].body if isinstance(n, ast.Assign)
                  and any(isinstance(t, ast.Name) and t.id == 'SPECS' for t in n.targets))
specs = ast.literal_eval(specs_node.value)
assert specs['api'][2] == {}
assert specs['api'][1] == 'sha256:a935b4144d18ebfb7486bcc014a4441eb8cd45c06b9f97cb5b19217e0cfccab3'
assert specs['worker'][1] == 'sha256:18a88c4dde6e09fb75122aef1f011fd11c7a0421e61559b0548ed78c1b8b3ecf'
assert set(specs['worker'][2]) == {'worker.py', 'outbox.py', 'outbox-source.py'}
manifest = json.loads((SOURCE / 'prepare-result.txt').read_text(encoding='utf-8-sig'))
assert manifest['stage'] == 'prepared_not_deployed'
roles = manifest['roles']
assert roles['api']['candidate_image'] == roles['api']['old_image'] == specs['api'][1]
assert roles['worker']['old_image'] == specs['worker'][1]
assert roles['worker']['candidate_image'] == 'sha256:bfde7c86f327360738d8f8864d90a49fabd5cd2305ff938b2708554bf9838b3a'
assert roles['worker']['files'] == {k: list(v) for k, v in specs['worker'][2].items()}

assert specs['worker'][2]['outbox.py'][0] == '/usr/local/lib/python3.12/site-packages/app/core/outbox.py'
assert specs['worker'][2]['outbox-source.py'][0] == '/opt/business-api/app/core/outbox.py'

source_paths = {'worker.py': 'services/business-worker/app/worker.py',
                'outbox.py': 'services/business-api/app/core/outbox.py',
                'outbox-source.py': 'services/business-api/app/core/outbox.py'}
for name, path in source_paths.items():
    payload = (SOURCE / name).read_bytes()
    assert hashlib.sha256(payload).hexdigest() == specs['worker'][2][name][2]
    frozen = subprocess.check_output(['git', 'show', '9920947c34e6c41a050a1fbb1d9cc7d7ac882749:' + path], cwd=ROOT)
    assert payload == frozen, 'Payload differs from domain-reviewed Git bytes'

switch_node = next(n for n in trees['deploy.py'].body if isinstance(n, ast.FunctionDef) and n.name == 'switch')
selected = ast.Module(body=[switch_node], type_ignores=[])


def replay(operation, corrupt=None):
    checks, commands = [], []
    config = b'synthetic frozen config'
    mock_roles = json.loads(json.dumps(roles))
    for row in mock_roles.values():
        row['config_hashes'] = dict.fromkeys(['candidate', 'rollback'], hashlib.sha256(config).hexdigest())

    class MemoryPath:
        def __truediv__(self, name):
            return self
        def read_bytes(self):
            return config
        def read_text(self):
            return '{}'
        def open(self, mode):
            return io.StringIO()
        def __str__(self):
            return 'synthetic-config'

    def check_output(command, **kwargs):
        assert command[:4] == ['docker', 'exec', roles['worker']['name'], 'python']
        assert kwargs == {'text': True, 'timeout': 10}
        for name, (target, old, new) in specs['worker'][2].items():
            if repr(target) in command[-1]:
                checks.append(name)
                return ('corrupt' if name == corrupt else new if operation == 'deploy' else old) + '\n'
        raise AssertionError('Unexpected source query')

    current = {'State': {'Running': True, 'Health': {'Status': 'healthy'}},
               'Image': roles['worker']['candidate_image' if operation == 'deploy' else 'old_image']}
    ns = {'guard_identity': lambda: None, 'roles': mock_roles, 'PRIVATE': MemoryPath(),
          'GUARD': 'synthetic-guard', 'hashlib': hashlib, 'json': json,
          'guarded_process': lambda cmd, output: commands.append(cmd),
          'inspect': lambda name: current, 'same_runtime': lambda old, new: None,
          'subprocess': SimpleNamespace(check_output=check_output)}
    exec(compile(selected, 'reviewed-switch', 'exec'), ns)
    failed = False
    try:
        assert ns['switch'](operation) == current
    except AssertionError:
        failed = True
    assert failed == (corrupt is not None)
    assert len(commands) == 1 and commands[0][-2:] == ['--service', 'business-worker']
    assert commands[0][2] == operation
    if corrupt is None:
        assert checks == ['worker.py', 'outbox.py', 'outbox-source.py']
    else:
        assert corrupt in checks


results = []
for operation in ['deploy', 'rollback']:
    for corrupt in [None, 'worker.py', 'outbox.py', 'outbox-source.py']:
        replay(operation, corrupt)
        results.append({'operation': operation, 'corrupt_file': corrupt, 'result': 'PASS'})

receipt_call = next(n for n in ast.walk(trees['deploy.py']) if isinstance(n, ast.Call)
                    and any(k.arg == 'source_sha256' for k in n.keywords))
value = next(k.value for k in receipt_call.keywords if k.arg == 'source_sha256')
receipt_sources = eval(compile(ast.Expression(value), 'reviewed-receipt-field', 'eval'), {'roles': roles})
assert receipt_sources == {name: row[2] for name, row in specs['worker'][2].items()}
print(json.dumps({'source_sha256': HASHES, 'payloads_equal_domain_review_commit': True,
                  'api_unchanged': True, 'paired_receipt': receipt_sources,
                  'scope': 'AST-only switch with inert mocks; local Git read; no Docker/DB/network/signal/deploy top level',
                  'passed': len(results), 'failed': 0, 'checks': results}, indent=2))
