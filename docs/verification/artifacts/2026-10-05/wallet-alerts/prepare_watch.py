import json,subprocess,os,copy,sys
from pathlib import Path
root=Path('/opt/starchat/releases/wallet-alerts-20261005');private=root/'private'
sys.path.insert(0,'/opt/starchat/ops/refresh-guards')
from business_release_guard import escape_interpolation
def run(args):return subprocess.run(args,capture_output=True,text=True,check=True).stdout
summary=json.loads((root/'baseline-summary.json').read_text());rollback=json.loads((root/'rollback-images.json').read_text())
source=(root/'prepare_release.py').read_text()
exec(compile(source[source.index('watch=json.loads'):],str(root/'prepare_release.py'),'exec'))
