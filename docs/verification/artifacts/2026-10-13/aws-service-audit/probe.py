import subprocess,json,datetime,shutil,os

def run(args):
 p=subprocess.run(args,capture_output=True,text=True,timeout=40)
 return {'exit':p.returncode,'stdout':p.stdout.strip()}
r={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
for key,args in {'uptime':['uptime'],'memory':['free','-m'],'disk':['df','-hT'],'inodes':['df','-i'],'failed':['systemctl','--failed','--no-pager','--plain'],'services':['systemctl','list-units','--type=service','--state=running','--no-pager','--plain'],'ports':['ss','-lntup'],'stats':['sudo','-n','docker','stats','--no-stream','--format','{{json .}}'],'docker_version':['sudo','-n','docker','version','--format','{{.Server.Version}}']}.items():
 try:r[key]=run(args)
 except Exception as e:r[key]={'error':type(e).__name__}
p=subprocess.run(['sudo','-n','docker','ps','-aq'],capture_output=True,text=True)
r['containers']=[]
if p.returncode==0 and p.stdout.strip():
 data=json.loads(subprocess.check_output(['sudo','-n','docker','inspect']+p.stdout.split()))
 for c in data:
  s=c['State']; h=s.get('Health',{})
  r['containers'].append({'name':c['Name'],'image':c['Config']['Image'],'state':s['Status'],'started':s['StartedAt'],'finished':s['FinishedAt'],'exit':s['ExitCode'],'oom':s['OOMKilled'],'restarts':c['RestartCount'],'health':h.get('Status'),'health_failures':h.get('FailingStreak'),'ports':c['NetworkSettings'].get('Ports'),'project':c['Config'].get('Labels',{}).get('com.docker.compose.project')})
p=subprocess.run(['sudo','-n','journalctl','-k','--since','24 hours ago','--no-pager','-o','cat'],capture_output=True,text=True)
r['kernel_24h']={'exit':p.returncode,'oom_lines':sum('out of memory' in x.lower() or 'killed process' in x.lower() for x in p.stdout.splitlines()),'io_error_lines':sum('i/o error' in x.lower() for x in p.stdout.splitlines())}
print(json.dumps(r))
