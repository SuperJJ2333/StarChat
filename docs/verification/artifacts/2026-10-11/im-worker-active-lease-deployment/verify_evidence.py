"""Bind downloaded non-sensitive receipts to the frozen Git script/payload bytes."""
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
PREFIX = str(HERE.relative_to(REPO)).replace('\\', '/')
FREEZE = '77ca608c7d98a147a2af4d657c2cb8c82be9e495'
def sha(data):
    return hashlib.sha256(data).hexdigest()
def load(name):
    return json.loads((HERE/name).read_text(encoding='utf-8'))
def git_bytes(path):
    return subprocess.check_output(['git','show',FREEZE+':'+PREFIX+'/'+path],cwd=REPO)

manifest = load('services-manifest.json')
receipt = load('default-runtime-receipt.json')
assert receipt['manifest_sha256'] == sha((HERE/'services-manifest.json').read_bytes())
assert receipt['image'] == manifest['roles']['worker']['candidate_image']
assert set(receipt['checks']) == {'default_entry','default_pytest'}
assert all(item['exit_code'] == item['cleanup_exit'] == 0 for item in receipt['checks'].values())
assert '70 passed, 1 skipped' in receipt['checks']['default_pytest']['stdout']
for name, digest in receipt['input_sha256'].items():
    if name == 'test-tools.zip':
        assert digest == '71a0a7c69a9027d17445d07808dd09e01919b19c61dad06e34dda3d2e6b380ee'
    else:
        assert sha(git_bytes(name)) == digest, name
spec = load('payload-spec.json')['roles']
for role, expected in spec.items():
    assert manifest['roles'][role]['old_image'] == expected[1]
    assert manifest['roles'][role]['files'] == expected[2]
for filename, (_target, _old, new) in manifest['roles']['worker']['files'].items():
    assert sha(git_bytes('worker/'+filename)) == new
protocol = load('protocol-check-output.txt')
expected_images = {('api',manifest['roles']['api']['old_image']),
    ('worker',manifest['roles']['worker']['candidate_image']),('worker',manifest['roles']['worker']['old_image'])}
assert {(row['role'],row['image']) for row in protocol} == expected_images
assert all(row['passed'] is True and len(row['checks']) == 9 for row in protocol)
restored = load('candidate-checks-receipt.json')
assert restored['checks'] == {'default_runtime_exit':0,'protocol_exit':0}
assert restored['before_count'] == restored['after_count'] == 60
assert restored['exact_container_ids_unchanged'] is True
assert restored['added'] == restored['removed'] == restored['changed'] == []
running = load('running-containers-after.json')
assert running['running_count'] == len(running['containers']) == 35
assert sha('\n'.join(sorted(running['containers'])).encode()) == running['running_container_id_set_sha256']
configuration = load('configuration-proof.json')['roles']
assert configuration['api']['fully_identical'] is True
assert configuration['worker']['only_image_may_differ'] is True
assert all(row['live_id_unchanged'] and row['live_image_unchanged'] for row in configuration.values())
names = ['prepare.py','deploy.py','validate_default_runtime.py','default_entry_probe.py']
for name in names:
    assert (HERE/name).read_bytes() == git_bytes(name), 'frozen script changed'
identities = {
    'result':'PASS','product_source_commit':'c3dd314212c73414c5ab371b4363e077bc9104c2',
    'source_review_commit':'cc1c372759d22c11e2e3f77e84d15ce3accba98e',
    'core_scripts_commit':FREEZE,'candidate_image':receipt['image'],
    'rollback_image':manifest['roles']['worker']['old_image'],
    'api_image':manifest['roles']['api']['old_image'],'deployed':False,
    'files': {str(path.relative_to(HERE)).replace('\\','/'):sha(path.read_bytes()) for path in sorted(HERE.rglob('*'))
        if path.is_file() and path.suffix in {'.py','.json','.md','.log','.txt'} and path.name != 'deployment-input-identities.json'},
}
(HERE/'deployment-input-identities.json').write_text(json.dumps(identities,indent=2)+'\n',encoding='utf-8',newline='\n')
print(json.dumps({'result':'PASS','candidate_image':receipt['image'],'core_scripts_unchanged':True,
                  'all_container_ids_unchanged':60,'current_running':35,'deployed':False}))
