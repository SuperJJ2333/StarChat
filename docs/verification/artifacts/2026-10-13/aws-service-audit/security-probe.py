import subprocess,json,datetime,urllib.request
r={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
p=subprocess.run(['aws','ec2','describe-instances','--region','ap-southeast-1','--filters','Name=private-ip-address,Values=172.31.46.134','--query','Reservations[].Instances[].{state:State.Name,type:InstanceType,groups:SecurityGroups[].GroupId}','--output','json'],capture_output=True,text=True,timeout=20);r['instance_exit']=p.returncode
if p.returncode==0:
 rows=json.loads(p.stdout);r['instances']=rows;ids=[g for x in rows for g in x['groups']]
 if ids:
  p=subprocess.run(['aws','ec2','describe-security-groups','--region','ap-southeast-1','--group-ids']+ids+['--query','SecurityGroups[].{group:GroupId,inbound:IpPermissions}','--output','json'],capture_output=True,text=True,timeout=20);r['sg_exit']=p.returncode
  if p.returncode==0:r['security_groups']=json.loads(p.stdout)
with urllib.request.urlopen('https://d2bc5pp65dxo0s.cloudfront.net/api/health',timeout=10) as resp:
 data=resp.read(16384);r['api_health']={'status':resp.status,'content_type':resp.headers.get('Content-Type'),'bytes':len(data)}
 try:
  obj=json.loads(data);r['api_health']['safe_fields']={k:v for k,v in obj.items() if k in ['status','ok','healthy','success'] and isinstance(v,(str,bool,int))}
 except Exception:r['api_health']['json']=False
print(json.dumps(r))
