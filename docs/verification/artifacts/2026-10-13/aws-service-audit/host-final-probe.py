import subprocess,json,datetime,os
r={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
for k,a in {'timers':['systemctl','list-timers','--all','--no-pager','--plain'],'user_failed':['systemctl','--user','--failed','--no-pager','--plain'],'user_services':['systemctl','--user','list-units','--type=service','--state=running','--no-pager','--plain'],'process_names':['ps','-eo','comm=']}.items():
 p=subprocess.run(a,capture_output=True,text=True,timeout=20);r[k]={'exit':p.returncode,'output':sorted(set(p.stdout.splitlines())) if k=='process_names' else p.stdout.strip()}
p=subprocess.run(['aws','ec2','describe-instances','--region','ap-southeast-1','--filters','Name=private-ip-address,Values=172.31.46.134','--query','Reservations[].Instances[].InstanceId','--output','json'],capture_output=True,text=True,timeout=20)
if p.returncode==0:
 ids=json.loads(p.stdout)
 p=subprocess.run(['aws','ec2','describe-instance-status','--region','ap-southeast-1','--instance-ids']+ids+['--query','InstanceStatuses[].{instance:InstanceStatus.Status,system:SystemStatus.Status,state:InstanceState.Name,events:Events[].Code}','--output','json'],capture_output=True,text=True,timeout=20);r['ec2_status']={'exit':p.returncode,'result':json.loads(p.stdout) if p.returncode==0 else None}
print(json.dumps(r))
