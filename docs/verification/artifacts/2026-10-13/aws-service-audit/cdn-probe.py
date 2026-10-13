import subprocess,json,datetime,re,concurrent.futures
r={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
c=json.loads(subprocess.check_output(['sudo','-n','docker','inspect','coscene-api']))[0];test=c['Config']['Healthcheck']['Test'];p=subprocess.run(['sudo','-n','docker','exec','coscene-api']+(['sh','-c',test[1]] if test[0]=='CMD-SHELL' else test[1:]),capture_output=True,text=True,timeout=20);r['actual_configured_api_health']={'exit':p.returncode,'paths':re.findall(r'127\.0\.0\.1:[0-9]+(/[a-zA-Z0-9/_-]*)',' '.join(test))}
p=subprocess.run(['aws','cloudfront','list-distributions','--output','json'],capture_output=True,text=True,timeout=25)
r['cloudfront']={'exit':p.returncode}
if p.returncode==0:
 d=json.loads(p.stdout);r['cloudfront']['distributions']=[{'domain':x['DomainName'],'status':x['Status'],'enabled':x['Enabled'],'aliases':x.get('Aliases',{}).get('Items',[]),'origins':[{'domain':o['DomainName'],'port':o.get('CustomOriginConfig',{}).get('HTTPSPort')} for o in x['Origins']['Items']]} for x in d.get('DistributionList',{}).get('Items',[])]
print(json.dumps(r))
