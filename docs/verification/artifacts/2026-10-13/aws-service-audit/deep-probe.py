import subprocess,json,re,datetime
r={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
def cmd(a):
 p=subprocess.run(a,capture_output=True,text=True,timeout=35);return p
ids=subprocess.check_output(['sudo','-n','docker','ps','-q'],text=True).split(); data=json.loads(subprocess.check_output(['sudo','-n','docker','inspect']+ids))
r['containers']=[]
for c in data:
 n=c['Name'][1:]; p=cmd(['sudo','-n','docker','logs','--since','15m','--tail','2000',n]); text=p.stdout+p.stderr
 row={'name':n,'restart_policy':c['HostConfig']['RestartPolicy'],'log_driver':c['HostConfig']['LogConfig'],'recent_log_lines':len(text.splitlines()),'error_keywords':{k:len(re.findall(k,text,re.I)) for k in ['panic','fatal','error','connection refused','timeout','permission denied']}}
 if 'nginx' in n or n=='coscene-edge':
  q=cmd(['sudo','-n','docker','exec',n,'nginx','-T']); row['nginx_config_exit']=q.returncode; row['server_names']=re.findall(r'^\s*server_name\s+([^;]+)',q.stdout,re.M);row['locations']=re.findall(r'^\s*location\s+([^\{]+)',q.stdout,re.M)
 if n=='ga-gold-aws-edge':
  q=cmd(['sudo','-n','docker','exec',n,'cat','/etc/caddy/Caddyfile']); row['caddy_hosts']=[x for x in q.stdout.splitlines() if re.match(r'^[a-zA-Z0-9][a-zA-Z0-9.:_-]+\s*\{',x)]; row['config_read_exit']=q.returncode
 r['containers'].append(row)
for k,a in {'redis_ping':['sudo','-n','docker','exec','coscene-redis','redis-cli','ping'],'pg_ready':['sudo','-n','docker','exec','coscene-postgres','pg_isready'],'enabled':['systemctl','is-enabled','docker','containerd','amazon-ssm-agent','coscene-stream-control-tunnel'],'tunnel':['systemctl','show','coscene-stream-control-tunnel','-p','ActiveState','-p','SubState','-p','NRestarts','-p','ActiveEnterTimestamp'],'boot':['uptime','-s']}.items():
 p=cmd(a);r[k]={'exit':p.returncode,'output':p.stdout.strip()}
print(json.dumps(r))
