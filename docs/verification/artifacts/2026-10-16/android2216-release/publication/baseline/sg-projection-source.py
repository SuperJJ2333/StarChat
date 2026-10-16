
import json,subprocess
from datetime import datetime,timezone
def aws(*args):return json.loads(subprocess.check_output(['/usr/bin/aws',*args,'--output','json'],text=True,timeout=30))
identity=aws('sts','get-caller-identity')
assert identity['Account']=='218022113852' and identity['Arn']=='arn:aws:sts::218022113852:assumed-role/StarChatSgMaintenanceRole/i-035b46916e4cf43eb'
cf=aws('cloudfront','get-distribution-config','--id','E30IR8IHK6PMXZ')
dist=aws('cloudfront','get-distribution','--id','E30IR8IHK6PMXZ')['Distribution']
assert dist['DomainName']=='d12fjr06o6tga5.cloudfront.net'
policy=json.loads(aws('s3api','get-bucket-policy','--bucket','starchat-installers-218022113852-sg')['Policy'])
print(json.dumps({'checked_at_utc':datetime.now(timezone.utc).isoformat(),'cloudfront':cf,'policy':policy,'identity':identity,'status':dist['Status']},ensure_ascii=False))
