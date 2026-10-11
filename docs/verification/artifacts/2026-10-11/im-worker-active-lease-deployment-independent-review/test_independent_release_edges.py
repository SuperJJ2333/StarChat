"""Actual frozen AST bodies with synthetic local files; never invoke Docker/SSH."""
import ast
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from types import SimpleNamespace

import pytest

HERE = Path(__file__).resolve().parent
FROZEN = HERE / "frozen"
IDENTITY = json.loads((HERE / "frozen-inputs.json").read_text(encoding="utf-8"))
SPEC = json.loads((FROZEN / "payload-spec.json").read_text(encoding="utf-8"))


def parsed(name):
    data = (FROZEN / name).read_bytes()
    assert hashlib.sha256(data).hexdigest() == IDENTITY["files"][name]["sha256"]
    return ast.parse(data, filename=name)


def functions(name, names, namespace):
    selected = [n for n in parsed(name).body if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name in names]
    assert {n.name for n in selected} == names
    exec(compile(ast.Module(body=selected, type_ignores=[]), name, "exec"), namespace)
    return namespace


def test_all_payloads_are_exact_reviewed_product_git_bytes_and_baseline():
    paths = {"main.py": "services/business-worker/app/main.py", "worker.py": "services/business-worker/app/worker.py",
             "lease_renewal.py": "services/business-worker/app/lease_renewal.py",
             "outbox.py": "services/business-api/app/core/outbox.py", "outbox-source.py": "services/business-api/app/core/outbox.py"}
    targets = SPEC["roles"]["worker"][2]
    assert len(targets) == 5 and len({x[0] for x in targets.values()}) == 5
    assert SPEC["source"] == "c3dd314212c73414c5ab371b4363e077bc9104c2"
    assert SPEC["roles"]["worker"][1] == "sha256:bfde7c86f327360738d8f8864d90a49fabd5cd2305ff938b2708554bf9838b3a"
    assert SPEC["roles"]["api"][2] == {}
    for name, source in paths.items():
        content = subprocess.check_output(["git", "show", SPEC["source"] + ":" + source], cwd=HERE.parents[4])
        assert content == (FROZEN / "worker" / name).read_bytes()
        assert hashlib.sha256(content).hexdigest() == targets[name][2]
        if name == "lease_renewal.py":
            assert targets[name][1] == "ABSENT"
            assert not subprocess.check_output(["git", "ls-tree", SPEC["base"], "--", source], cwd=HERE.parents[4])
        else:
            old = subprocess.check_output(["git", "show", SPEC["base"] + ":" + source], cwd=HERE.parents[4])
            assert hashlib.sha256(old).hexdigest() == targets[name][1]
    assert (FROZEN / "worker/outbox.py").read_bytes() == (FROZEN / "worker/outbox-source.py").read_bytes()
    for name in ("test_worker_active_lease.py", "test_published_worker_entrypoint.py", "test_worker_claim_fencing.py", "test_worker_lease_window.py"):
        assert (FROZEN / "tests" / name).read_bytes() == subprocess.check_output(
            ["git", "show", SPEC["source"] + ":tests/business_worker/" + name], cwd=HERE.parents[4])


def prepare_namespace(tmp_path, drift=None):
    root = tmp_path
    private = root / "private"
    private.mkdir()
    shutil.copytree(FROZEN / "worker", root / "worker")
    calls = []
    baseline = {}
    configs = {}
    for role, (name, base, _) in SPEC["roles"].items():
        path = root / (role + "-original.json")
        config = {"name": "starchat", "services": {"business-" + role: {
            "image": base, "environment": {"SYNTHETIC": "literal$dollar"},
            "logging": {"driver": "json-file", "options": {"max-size": "20m", "max-file": "10"}},
            "volumes": ["/synthetic:/data:ro"], "networks": ["existing"],
            "depends_on": {"unrelated": {"condition": "service_started"}}},
            "unrelated": {"image": "synthetic-unrelated"}},
            "networks": {"existing": {"external": True}}}
        path.write_text(json.dumps(config), encoding="utf-8")
        configs[str(path)] = config
        baseline[name] = {"Id": "synthetic-" + role, "Image": base, "Config": {
            "Env": ["SYNTHETIC=literal$dollar"], "Labels": {
                "com.docker.compose.project.config_files": str(path), "com.docker.compose.service": "business-" + role}}}
    def output(*argv):
        calls.append(argv)
        if argv[:2] == ("docker", "inspect"):
            return json.dumps([baseline[argv[2]]])
        if argv[:3] == ("docker", "image", "inspect"):
            return "sha256:" + "c" * 64
        if argv[:2] == ("docker", "ps"):
            return "synthetic-api id-api\nsynthetic-worker id-worker\n"
        raise AssertionError(argv)
    def run(argv, **kwargs):
        calls.append(tuple(argv))
        if argv[:2] == ["docker", "compose"]:
            return SimpleNamespace(returncode=0, stdout=json.dumps(configs[argv[argv.index("-f") + 1]]), stderr="")
        assert argv[:2] == ["docker", "build"]
        assert kwargs["check"] is True and kwargs["timeout"] == 180
        assert "--network=none" in argv and "--pull=false" in argv
        return SimpleNamespace(returncode=0)
    checked = []
    def source_sha(name, target):
        checked.append((name, target))
        for filename, (destination, old, _) in SPEC["roles"]["worker"][2].items():
            if target == destination:
                return "drift" if filename == drift else old
        raise AssertionError(target)
    namespace = {"ROOT": root, "PRIVATE": private, "SPECS": copy.deepcopy(SPEC["roles"]),
                 "Path": Path, "copy": copy, "hashlib": hashlib, "json": json,
                 "subprocess": SimpleNamespace(run=run, STDOUT=-2), "output": output, "source_sha": source_sha}
    functions("prepare.py", {"escape"}, namespace)
    # Windows modes do not expose POSIX permission bits. Omit only this explicit
    # platform assertion, retaining all transaction/build/config code unchanged.
    body = parsed("prepare.py").body
    first = next(i for i, n in enumerate(body) if isinstance(n, ast.Assert))
    body = [n for n in body[first:] if not (isinstance(n, ast.Assert) and isinstance(n.msg, ast.Constant) and n.msg.value == "private snapshot permissions")]
    return namespace, calls, checked, ast.Module(body=body, type_ignores=[])


def test_actual_prepare_changes_only_worker_image_and_preserves_literal_environment(tmp_path):
    ns, calls, checked, body = prepare_namespace(tmp_path)
    exec(compile(body, "prepare.py", "exec"), ns)
    for role in ("api", "worker"):
        old = json.loads((tmp_path / "private" / (role + "-rollback.json")).read_text())
        new = json.loads((tmp_path / "private" / (role + "-candidate.json")).read_text())
        assert set(new["services"]) == {"business-" + role}
        assert new["services"]["business-" + role]["environment"] == {"SYNTHETIC": "literal$$dollar"}
        if role == "worker":
            assert new["services"]["business-worker"]["image"] == "sha256:" + "c" * 64
            new["services"]["business-worker"]["image"] = old["services"]["business-worker"]["image"]
        assert old == new
    assert len(checked) == 5
    builds = [argv for argv in calls if argv[:2] == ("docker", "build")]
    assert len(builds) == 1 and builds[0][-1] == str(tmp_path / "worker")
    dockerfile = (tmp_path / "worker/Dockerfile").read_text()
    assert dockerfile.splitlines()[0] == "FROM " + SPEC["roles"]["worker"][1]
    assert len(dockerfile.splitlines()) == 6


@pytest.mark.parametrize("drift", ["main.py", "lease_renewal.py", "outbox.py", "outbox-source.py", "worker.py"])
def test_prepare_any_of_five_runtime_drifts_stops_before_image_build(tmp_path, drift):
    ns, calls, checked, body = prepare_namespace(tmp_path, drift)
    with pytest.raises(AssertionError, match="runtime source drift"):
        exec(compile(body, "prepare.py", "exec"), ns)
    assert not any(argv[:2] == ("docker", "build") for argv in calls)
    assert not (tmp_path / "services-manifest.json").exists()


@pytest.mark.parametrize("operation,wrong", [("rollback", "lease_renewal.py"), ("deploy", "outbox.py")])
def test_switch_rejects_leftover_lease_and_wrong_installed_consumer(tmp_path, operation, wrong):
    private = tmp_path / "private"
    private.mkdir()
    (private / "worker-inspect.json").write_text("{}")
    roles = {}
    for role in ("api", "worker"):
        hashes = {}
        for kind in ("candidate", "rollback"):
            path = private / f"{role}-{kind}.json"
            path.write_text("{}")
            hashes[kind] = hashlib.sha256(path.read_bytes()).hexdigest()
        roles[role] = {"config_hashes": hashes}
    roles["worker"].update(name="synthetic-worker", candidate_image="candidate", old_image="old", files=SPEC["roles"]["worker"][2])
    commands = []
    def source_sha(_name, path):
        for name, (target, old, new) in roles["worker"]["files"].items():
            if path == target:
                return "wrong-existing-file" if name == wrong else (new if operation == "deploy" else old)
        raise AssertionError(path)
    ns = {"PRIVATE": private, "roles": roles, "GUARD": Path("synthetic-guard"), "hashlib": hashlib, "json": json,
          "guard_identity": lambda: None, "guarded_process": lambda command, _output: commands.append(command),
          "inspect": lambda _: {"Image": "candidate" if operation == "deploy" else "old", "State": {"Running": True, "Health": {"Status": "healthy"}}},
          "same_runtime": lambda *_: None, "source_sha": source_sha}
    with pytest.raises(AssertionError):
        functions("deploy.py", {"switch"}, ns)["switch"](operation)
    assert len(commands) == 1
    assert commands[0][-2:] == ["--service", "business-worker"]
    assert commands[0][2] == operation
