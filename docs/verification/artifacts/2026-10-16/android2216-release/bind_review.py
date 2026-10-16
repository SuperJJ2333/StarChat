"""Record the completed independent reviews for the user's authorized release."""
from pathlib import Path
import hashlib,json
H=Path(__file__).resolve().parent
P=H/'publication-final-2216-20261016'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
f=json.loads((P/'freeze-manifest.json').read_text(encoding='utf-8'))
checks={}
for key,name in [('spec_domain','spec-publication.md'),('quality_security','quality-publication.md')]:
    p=H/'reviews'/name
    text=p.read_text(encoding='utf-8')
    assert 'PASS' in text and '5df015a69df956450a6e1d8ec9c728324fce9c3bfa1be2863f18385aa3d551a6' in text
    checks[key]={'status':'pass','path':name,'sha256':sha(p)}
r={k:f[k] for k in ['artifact_sha256','runtime_sha256','source_commit']}
r.update(freeze_sha256=sha(P/'freeze-manifest.json'),operation_id='experience-20261016-2216',authorized_operations=['preflight','runtime','upload','assemble','hk-install','cdn-install','cdn-check','hk-switch','publish','inspect','audit'],checks=checks)
with (H/'reviews/release-review.json').open('x',encoding='utf-8') as out:json.dump(r,out,indent=2)
print('REVIEW_BOUND_TO_FROZEN_PACKAGE')
