"""Read-only selected identities. Never emit runtime env, DSN or user rows."""
import hashlib
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

def output(*args, timeout=15):
    return subprocess.check_output(args, text=True, timeout=timeout)

result = {"observed_utc": datetime.now(timezone.utc).isoformat(), "roles": {}}
for role in ("api", "worker"):
    name = "starchat-business-" + role + "-1"
    live = json.loads(output("docker", "inspect", name))[0]
    paths = live["Config"]["Labels"]["com.docker.compose.project.config_files"].split(",")
    result["roles"][role] = {
        "name": name, "id": live["Id"], "image": live["Image"],
        "running": live["State"]["Running"], "health": live["State"].get("Health", {}).get("Status"),
        "restart_count": live["RestartCount"], "oom_killed": live["State"].get("OOMKilled"),
        "compose_layers": {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths},
    }
for filename in ("business_release_guard.py", "business_refresh_image_probe.py"):
    result[filename] = hashlib.sha256((Path("/opt/starchat/ops/refresh-guards") / filename).read_bytes()).hexdigest()
code = """from app.core.config import Settings
from sqlalchemy import create_engine,text
e=create_engine(Settings().database_url,connect_args={'connect_timeout':3})
with e.begin() as c:
 c.execute(text('SET TRANSACTION READ ONLY'))
 c.execute(text("SET LOCAL statement_timeout='5s'"))
 print(c.execute(text('SELECT version_num FROM alembic_version')).scalar_one())
e.dispose()
"""
result["schema"] = output("docker", "exec", result["roles"]["api"]["name"], "python", "-c", code, timeout=12).strip()
print(json.dumps(result, indent=2))
