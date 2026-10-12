from pathlib import Path
from datetime import datetime
import base64,json,subprocess,sys,hashlib,shlex
kind=sys.argv[1]
here=Path(__file__).resolve().parent
root=Path(r"D:/pythonProject/outsource/StarChat")
source=here/(kind+"-projection-source.py")
command="python3 -B -c "+shlex.quote("import base64;exec(base64.b64decode("+repr(base64.b64encode(source.read_bytes()).decode())+"))")
if kind=="hk":
 args=["pwsh.exe","-NoProfile","-File",str(root/"scripts/starchat-server.ps1"),"-Action","Command","-RemoteCommand",command]
else:
 args=["ssh","-o","BatchMode=yes","-o","StrictHostKeyChecking=yes","-o","ConnectTimeout=10","-J","jumper","-o","HostKeyAlias=13.229.60.153","-i",str(Path.home()/".ssh/tee_13153299.pem"),"ec2-user@18.143.207.225",command]
started=datetime.now().astimezone().isoformat()
r=subprocess.run(args,capture_output=True,text=True,encoding="utf-8",timeout=180)
if r.returncode:
 print(json.dumps({"kind":kind,"exit_code":r.returncode,"transport_error":"REMOTE_COMMAND_FAILED_NO_RAW_OUTPUT"},ensure_ascii=False));sys.exit(r.returncode)
snapshot=json.loads(r.stdout)
if kind=="hk":
 files=snapshot.pop("files")
 static={"files":{n:{k:v for k,v in x.items() if k!="base64"} for n,x in files.items()},"registry":snapshot["registry"],"latest_arm64":snapshot["aliases"]["latest-arm64.apk"]}
 for name,identity in files.items():
  dest=here/"hk-snapshot"/name;dest.parent.mkdir(parents=True,exist_ok=True);b=base64.b64decode(identity["base64"]);assert hashlib.sha256(b).hexdigest()==identity["sha256"];dest.write_bytes(b)
 extra=[("static-baseline.json",static),("settings-before.json",snapshot["settings"])]
 summary={"android":snapshot["settings"]["app_latest_version"]+"+"+snapshot["settings"]["app_latest_build"],"ios":snapshot["settings"]["app_ios_latest_version"]+"+"+snapshot["settings"]["app_ios_latest_build"],"schema":snapshot["schema"],"aliases":snapshot["aliases"],"target_exists":snapshot["target_exists"],"containers":len(snapshot["runtime"])}
else:
 extra=[("cloudfront-before.json",snapshot["cloudfront"]),("bucket-policy-before.json",snapshot["policy"])]
 summary={"etag":snapshot["cloudfront"]["ETag"],"status":snapshot["status"],"routes":snapshot["cloudfront"]["DistributionConfig"]["CacheBehaviors"]["Quantity"]}
for name,value in [(kind+"-live-snapshot.json",snapshot),*extra]:
 (here/name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
meta={"kind":kind,"started":started,"ended":datetime.now().astimezone().isoformat(),"exit_code":r.returncode,"projection_source_sha256":hashlib.sha256(source.read_bytes()).hexdigest(),"checked_at_utc":snapshot["checked_at_utc"],"summary":summary}
(here/(kind+"-projection-metadata.json")).write_text(json.dumps(meta,ensure_ascii=False,indent=2),encoding="utf-8");print(json.dumps(meta,ensure_ascii=False,indent=2))
