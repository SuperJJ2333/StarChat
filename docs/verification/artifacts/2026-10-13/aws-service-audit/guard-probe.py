import subprocess,json,re,datetime,concurrent.futures
r={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
for n in ['coscene-edge','starchat-sg-edge-nginx-20260927']:
 p=subprocess.run(['sudo','-n','docker','exec',n,'nginx','-T'],capture_output=True,text=True)
 text=p.stdout
 r[n]={'403_rules':sum('return 403' in l for l in text.splitlines()),'custom_header_guard':bool(re.search(r'\$http_[^\s;]*(?:secret|origin|token|key)',text,re.I)),'routing':[l.strip() for l in text.splitlines() if re.match(r'^\s*(map |upstream |ssl_preread |server [0-9a-zA-Z]|[a-zA-Z][a-zA-Z0-9.-]+\.com\s)',l) and not re.search(r'key|secret|token',l,re.I)]}
p=subprocess.run(['sudo','-n','docker','exec','coscene-api','node','-e',"fetch('http://127.0.0.1:3001/health').then(async r=>console.log(JSON.stringify({status:r.status}))).catch(e=>{console.log(JSON.stringify({error:e.name}));process.exitCode=1})"],capture_output=True,text=True,timeout=15);r['api_direct']={'exit':p.returncode,'result':p.stdout.strip()}
p=subprocess.run(['sudo','-n','journalctl','-u','coscene-stream-control-tunnel','--since','15 minutes ago','--no-pager','-o','cat'],capture_output=True,text=True);r['tunnel_errors']={k:len(re.findall(k,p.stdout,re.I)) for k in ['refused','failed','timeout','broken pipe']}
print(json.dumps(r))
