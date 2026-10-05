import json,subprocess,hashlib,time,os
from pathlib import Path
root=Path('/opt/starchat/releases/wallet-alerts-20261005');private=root/'private';images=json.loads((root/'images.json').read_text());baseline=json.loads((root/'baseline-summary.json').read_text())
def run(args):return subprocess.run(args,capture_output=True,text=True,check=True).stdout
def inspect(name):return json.loads(run(['docker','inspect',name]))[0]
source=(root/'deploy_release.py').read_text()
# Reuse read-only postflight after the recorded switch; never repeat migration/deployment.
exec(compile(source[source.index('snapshot='):source.index('before=state()')],str(root/'deploy_release.py'),'exec'))
before=json.loads((root/'pre-deploy-control.json').read_text())
exec(compile(source[source.index('manifest=json.loads'):],str(root/'deploy_release.py'),'exec'))
