import subprocess,json,datetime,socket,concurrent.futures,re
r={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'dns':socket.gethostbyname_ex('sg.liuhetong888.com')}
def check(item):
 url,resolve=item;a=['curl','-sS','--max-time','8','-o','/dev/null','-w','%{http_code} %{time_total} %{remote_ip}']
 if resolve:a+=['--resolve',resolve]
 p=subprocess.run(a+[url],capture_output=True,text=True);return {'url':url,'resolve':resolve,'exit':p.returncode,'result':p.stdout,'error':p.stderr[:220]}
items=[('https://sg.liuhetong888.com:18443/healthz','sg.liuhetong888.com:18443:127.0.0.1'),('https://sg.liuhetong888.com:18443/','sg.liuhetong888.com:18443:127.0.0.1'),('https://sg.liuhetong888.com:18443/api/health','sg.liuhetong888.com:18443:127.0.0.1'),('https://sg.liuhetong888.com:28443/','sg.liuhetong888.com:28443:127.0.0.1'),('https://sg.liuhetong888.com/health/live','sg.liuhetong888.com:443:127.0.0.1')]
with concurrent.futures.ThreadPoolExecutor(max_workers=5) as ex:r['local_tls']=list(ex.map(check,items))
for n in ['coscene-postgres','coscene-redis']:
 c=json.loads(subprocess.check_output(['sudo','-n','docker','inspect',n]))[0];env=dict(x.split('=',1) for x in c['Config']['Env'] if '=' in x)
 if n.endswith('postgres'):a=['sudo','-n','docker','exec',n,'pg_isready','-U',env.get('POSTGRES_USER','postgres'),'-d',env.get('POSTGRES_DB',env.get('POSTGRES_USER','postgres'))]
 else:a=['sudo','-n','docker','exec',n,'sh','-c','REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping']
 p=subprocess.run(a,capture_output=True,text=True);r[n]={'exit':p.returncode,'ready':('accepting connections' in p.stdout) if n.endswith('postgres') else p.stdout.strip()=='PONG','auth_required':'NOAUTH' in p.stdout}
p=subprocess.run(['sudo','-n','docker','logs','--since','15m','coscene-postgres'],capture_output=True,text=True);r['pg_shutdown_admin_termination']=sum('terminating connection due to administrator command' in x for x in (p.stdout+p.stderr).splitlines())
print(json.dumps(r))
