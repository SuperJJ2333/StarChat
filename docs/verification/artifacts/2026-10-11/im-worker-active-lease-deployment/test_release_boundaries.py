"""No Docker/SSH/signals: run selected real script functions with inert edges."""
import ast
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from contextlib import redirect_stdout
from io import StringIO
import stat
from types import SimpleNamespace

import pytest

HERE = Path(__file__).resolve().parent


def functions(filename, names, namespace):
    tree = ast.parse((HERE / filename).read_text(encoding="utf-8"))
    nodes = [node for node in tree.body if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in names]
    assert {node.name for node in nodes} == set(names)
    exec(compile(ast.Module(body=nodes, type_ignores=[]), filename, "exec"), namespace)
    return namespace


@pytest.mark.parametrize("operation", ["rollback", "deploy"])
def test_five_destinations_verify_new_module_absent_on_rollback(tmp_path, operation):
    private = tmp_path / "private"
    private.mkdir()
    (private / "worker-inspect.json").write_text("{}")
    files = {}
    for name in ("main.py", "worker.py", "lease_renewal.py", "outbox.py", "outbox-source.py"):
        target = tmp_path / name
        old = b"old synthetic source"
        new = b"new synthetic source"
        old_sha = "ABSENT" if name == "lease_renewal.py" else hashlib.sha256(old).hexdigest()
        if operation == "deploy":
            target.write_bytes(new)
        elif old_sha != "ABSENT":
            target.write_bytes(old)
        files[name] = (str(target), old_sha, hashlib.sha256(new).hexdigest())
    roles = {}
    for role in ("api", "worker"):
        hashes = {}
        for kind in ("rollback", "candidate"):
            path = private / f"{role}-{kind}.json"
            path.write_text("{}")
            hashes[kind] = hashlib.sha256(path.read_bytes()).hexdigest()
        roles[role] = {"config_hashes": hashes}
    roles["worker"].update(name="synthetic-worker", candidate_image="candidate", old_image="old", files=files)
    checked = []
    def check_output(argv, **kwargs):
        assert argv[:5] == ["docker", "exec", "synthetic-worker", "python", "-c"]
        checked.append(argv[-1])
        # Execute the actual digest snippet only against our synthetic temp files.
        return subprocess.check_output([sys.executable, "-c", argv[-1]], text=True, timeout=2)
    namespace = {
        "PRIVATE": private, "roles": roles, "GUARD": Path("synthetic-guard"),
        "guard_identity": lambda: None, "hashlib": hashlib, "json": json,
        "guarded_process": lambda *_: None,
        "inspect": lambda _: {"Image": "candidate" if operation == "deploy" else "old",
            "State": {"Running": True, "Health": {"Status": "healthy"}}},
        "same_runtime": lambda *_: None,
        "subprocess": SimpleNamespace(check_output=check_output),
    }
    tree = ast.parse((HERE / "deploy.py").read_text(encoding="utf-8"))
    names = {"switch"}
    if any(isinstance(node, ast.FunctionDef) and node.name == "source_sha" for node in tree.body):
        names.add("source_sha")
    functions("deploy.py", names, namespace)["switch"](operation)
    assert len(checked) == 5


def test_missing_new_module_in_candidate_is_rejected(tmp_path):
    # Added once source_sha exists; the first rollback test already proves the
    # old implementation cannot distinguish deliberate ABSENT from read errors.
    ns = {"subprocess": subprocess}
    tree = ast.parse((HERE / "deploy.py").read_text(encoding="utf-8"))
    if not any(isinstance(node, ast.FunctionDef) and node.name == "source_sha" for node in tree.body):
        pytest.skip("source helper not implemented in baseline")
    calls = []
    def output(argv, **kwargs):
        calls.append(argv)
        return subprocess.check_output([sys.executable, "-c", argv[-1]], text=True, timeout=2)
    ns["subprocess"] = SimpleNamespace(check_output=output)
    digest = functions("deploy.py", {"source_sha"}, ns)["source_sha"]("synthetic", str(tmp_path / "missing.py"))
    assert digest == "ABSENT"
    assert digest != hashlib.sha256(b"new module").hexdigest()


@pytest.mark.parametrize("error", [PermissionError, OSError])
def test_absent_does_not_swallow_read_or_permission_failures(error):
    class FailedPath:
        def lstat(self):
            raise error("synthetic read failure")
    def output(argv, **kwargs):
        snippet = ast.parse(argv[-1])
        snippet.body = [node for node in snippet.body if not isinstance(node, ast.ImportFrom)]
        capture = StringIO()
        with redirect_stdout(capture):
            exec(compile(snippet, "source-digest-probe", "exec"), {"Path": lambda *_: FailedPath()})
        return capture.getvalue()
    namespace = {"subprocess": SimpleNamespace(check_output=output)}
    with pytest.raises(error):
        functions("deploy.py", {"source_sha"}, namespace)["source_sha"]("synthetic", "/synthetic")


def test_nonregular_path_is_not_misclassified_absent(tmp_path):
    def output(argv, **kwargs):
        return subprocess.check_output([sys.executable, "-c", argv[-1]], text=True, timeout=2)
    namespace = {"subprocess": SimpleNamespace(check_output=output)}
    with pytest.raises(subprocess.CalledProcessError):
        functions("deploy.py", {"source_sha"}, namespace)["source_sha"]("synthetic", str(tmp_path))


@pytest.mark.parametrize("timeout,cleanup_code", [(False, 0), (True, 0), (True, 7)])
def test_isolated_validation_bounds_and_cleans_only_own_container(tmp_path, timeout, cleanup_code):
    calls = []
    def run(argv, **kwargs):
        calls.append((argv, kwargs))
        if len(calls) == 1:
            if timeout:
                raise subprocess.TimeoutExpired(argv, 90)
            return SimpleNamespace(returncode=0, stdout="PASS", stderr="")
        return SimpleNamespace(returncode=cleanup_code, stdout="", stderr="synthetic cleanup failure")
    namespace = {"ROOT": tmp_path, "uuid4": lambda: SimpleNamespace(hex="syntheticowned"),
        "subprocess": SimpleNamespace(run=run, TimeoutExpired=subprocess.TimeoutExpired)}
    result = functions("validate_default_runtime.py", {"isolated_check"}, namespace)["isolated_check"](
        "synthetic-image", "pass", [("test.py", "/test.py")])
    argv = calls[0][0]
    assert argv[argv.index("--name") + 1] == "starchat-active-lease-probe-syntheticowned"
    assert argv[argv.index("--network") + 1] == "none" and "--read-only" in argv
    assert argv[argv.index("--cap-drop") + 1] == "ALL"
    assert not any("PYTHONPATH" in arg for arg in argv)
    assert calls[0][1]["timeout"] == 90
    assert calls[1][0] == ["docker", "rm", "-f", "starchat-active-lease-probe-syntheticowned"]
    assert calls[1][1]["timeout"] == 15
    assert result["exit_code"] == (124 if timeout else 0)
    assert result["cleanup_exit"] == cleanup_code


@pytest.mark.parametrize("drift", [None, "image", "manifest", "input", "cleanup", "missing_check"])
def test_deployment_requires_exact_successful_default_runtime_evidence(tmp_path, drift):
    manifest = tmp_path / "services-manifest.json"
    manifest.write_text("synthetic immutable manifest")
    names = {"validate_default_runtime.py", "default_entry_probe.py", "test-tools.zip",
        "tests/test_worker_active_lease.py", "tests/test_published_worker_entrypoint.py",
        "tests/test_worker_claim_fencing.py", "tests/test_worker_lease_window.py"}
    inputs = {}
    for name in names:
        path = tmp_path / name
        path.parent.mkdir(exist_ok=True)
        path.write_text("synthetic immutable input")
        inputs[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    receipt = {"image": "candidate", "manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
        "checks": {name: {"exit_code": 0, "cleanup_exit": 0} for name in ("default_entry", "default_pytest")},
        "input_sha256": inputs}
    if drift == "image": receipt["image"] = "wrong"
    if drift == "manifest": manifest.write_text("changed")
    if drift == "input": (tmp_path / "default_entry_probe.py").write_text("changed")
    if drift == "cleanup": receipt["checks"]["default_pytest"]["cleanup_exit"] = 124
    if drift == "missing_check": del receipt["checks"]["default_pytest"]
    (tmp_path / "default-runtime-receipt.json").write_text(json.dumps(receipt))
    namespace = {"ROOT": tmp_path, "json": json, "hashlib": hashlib,
        "roles": {"worker": {"candidate_image": "candidate"}}}
    check = functions("deploy.py", {"default_runtime_evidence"}, namespace)["default_runtime_evidence"]
    if drift is None:
        check()
    else:
        with pytest.raises(AssertionError):
            check()
