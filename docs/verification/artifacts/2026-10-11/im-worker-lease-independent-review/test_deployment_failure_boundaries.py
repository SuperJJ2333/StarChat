"""Local AST-selected fault tests: no deploy module import, network, Docker or OS signals."""

import ast
import hashlib
import json
from pathlib import Path
import subprocess
from types import SimpleNamespace


SOURCE = Path(
    "C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/"
    "docs/verification/artifacts/2026-10-11/im-worker-jit-deployment/deploy.py"
)
EXPECTED = "dc5e6dc8f02f6f1d01d79bb635fcab6545b57b105aa048a34d1cc542c4a94b44"
data = SOURCE.read_bytes()
assert hashlib.sha256(data).hexdigest() == EXPECTED, "source changed: request new review identity"
tree = ast.parse(data.decode("utf-8-sig"), filename=str(SOURCE))
names = {"UncertainSwitch", "guarded_process", "read_scalar", "schema", "processing_count", "inspect"}
selected = ast.Module(
    body=[node for node in tree.body if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in names],
    type_ignores=[],
)
assert len(selected.body) == len(names)
boundary = next(
    node for node in tree.body
    if isinstance(node, ast.Try)
    and isinstance(node.body[0], ast.Assign)
    and isinstance(node.body[0].value, ast.Call)
    and getattr(node.body[0].value.func, "id", None) == "switch"
)


class FakeProcess:
    pid = 424242

    def __init__(self, results):
        self.results = iter(results)
        self.wait_timeouts = []

    def wait(self, *, timeout):
        self.wait_timeouts.append(timeout)
        value = next(self.results)
        if isinstance(value, BaseException):
            raise value
        return value


def environment(results=(0,), *, missing_group=False, output="0\n", output_error=None):
    calls = {"popen": [], "signals": [], "check_output": []}
    process = FakeProcess(results)

    def popen(command, **kwargs):
        calls["popen"].append((command, kwargs))
        return process

    def killpg(pid, sig):
        calls["signals"].append((pid, sig))
        if missing_group:
            raise ProcessLookupError("synthetic missing process group")

    def check_output(command, **kwargs):
        calls["check_output"].append((command, kwargs))
        if output_error:
            raise output_error
        return output

    namespace = {
        "subprocess": SimpleNamespace(
            Popen=popen, check_output=check_output, STDOUT=-2,
            TimeoutExpired=subprocess.TimeoutExpired,
            CalledProcessError=subprocess.CalledProcessError,
        ),
        "os": SimpleNamespace(killpg=killpg),
        "signal": SimpleNamespace(SIGTERM=15, SIGKILL=9),
        "roles": {"api": {"name": "synthetic-api"}},
        "json": json,
    }
    exec(compile(selected, str(SOURCE), "exec"), namespace)
    return namespace, calls, process


def raises(kind, operation):
    try:
        operation()
    except kind as error:
        return error
    raise AssertionError(f"expected {kind.__name__}")


def boundary_result(namespace, deployment_error=None, rollback_error=None):
    operations, writes, emitted = [], [], []

    class MemoryPath:
        def __truediv__(self, _name):
            return self

        def write_text(self, value):
            writes.append(json.loads(value))

    def switch(operation):
        operations.append(operation)
        if operation == "deploy" and deployment_error:
            raise deployment_error
        if operation == "rollback" and rollback_error:
            raise rollback_error
        return {"Id": "synthetic-worker", "Image": "synthetic-image"}

    namespace.update({
        "switch": switch, "schema": lambda: "synthetic-schema-mismatch",
        "receipt": {"stage": "deploying"}, "ROOT": MemoryPath(),
        "emit": lambda stage, **data: emitted.append((stage, data)),
    })
    error = raises(SystemExit, lambda: exec(compile(ast.Module(body=[boundary], type_ignores=[]), str(SOURCE), "exec"), namespace))
    assert error.code == 1
    assert len(writes) == 1 and emitted[0][0] == "failed"
    return operations, writes[0]


results = []


def record(name, operation):
    operation()
    results.append({"name": name, "result": "PASS"})


def successful_guard():
    ns, calls, process = environment()
    ns["guarded_process"](["synthetic-guard"], object())
    assert calls["popen"][0][1]["start_new_session"] is True
    assert process.wait_timeouts == [480]
    assert calls["signals"] == []


def outer_timeout(missing_group=False):
    timeout = subprocess.TimeoutExpired("synthetic-guard", 480)
    ns, calls, process = environment((timeout, timeout, 0), missing_group=missing_group)
    error = raises(ns["UncertainSwitch"], lambda: ns["guarded_process"](["synthetic-guard"], object()))
    assert calls["signals"] == [(process.pid, 15), (process.pid, 9)]
    assert process.wait_timeouts == [480, 5, 5]
    operations, receipt = boundary_result(ns, error)
    assert operations == ["deploy"] and "rolled_back" not in receipt
    assert receipt["failure_type"] == "UncertainSwitch"
    assert "automatic rollback withheld" in receipt["recovery_required"]


def inner_timeout_exit_one():
    # The fixed guard collapses its internal Compose timeout to exit 1.
    # A nonzero guard result therefore cannot prove Docker daemon quiescence.
    ns, calls, _process = environment((1,))
    error = raises(ns["UncertainSwitch"], lambda: ns["guarded_process"](["synthetic-guard"], object()))
    operations, receipt = boundary_result(ns, error)
    assert calls["signals"] == []
    assert operations == ["deploy"] and "rolled_back" not in receipt
    assert "recovery_required" in receipt


def timeout_cleanup_failure_still_withholds_rollback():
    timeout = subprocess.TimeoutExpired("synthetic-guard", 480)
    ns, _calls, _process = environment((timeout,))

    def cleanup_failure(_pid, _sig):
        raise PermissionError("synthetic process-group cleanup failure")

    ns["os"].killpg = cleanup_failure
    error = raises(ns["UncertainSwitch"], lambda: ns["guarded_process"](["synthetic-guard"], object()))
    operations, receipt = boundary_result(ns, error)
    assert operations == ["deploy"] and "rolled_back" not in receipt
    assert receipt["failure_type"] == "UncertainSwitch"


def unexpected_wait_error_still_withholds_rollback():
    ns, _calls, _process = environment((OSError("synthetic wait syscall failure"),))
    error = raises(ns["UncertainSwitch"], lambda: ns["guarded_process"](["synthetic-guard"], object()))
    operations, receipt = boundary_result(ns, error)
    assert operations == ["deploy"] and "rolled_back" not in receipt
    assert receipt["failure_type"] == "UncertainSwitch"


def completed_switch_postcondition_failure():
    ns, _calls, _process = environment()
    operations, receipt = boundary_result(ns)
    assert operations == ["deploy", "rollback"]
    assert receipt["rolled_back"] is True and receipt["stage"] == "FAILED"


def uncertain_rollback_stays_failed():
    ns, _calls, _process = environment()
    operations, receipt = boundary_result(ns, rollback_error=ns["UncertainSwitch"]("synthetic"))
    assert operations == ["deploy", "rollback"]
    assert "rolled_back" not in receipt
    assert receipt["rollback_failure_type"] == "UncertainSwitch" and receipt["stage"] == "FAILED"


def readonly_query():
    ns, calls, _process = environment(output="0095_wallet_source_alerts\n")
    assert ns["schema"]() == "0095_wallet_source_alerts"
    command, kwargs = calls["check_output"][0]
    assert command[:5] == ["docker", "exec", "synthetic-api", "python", "-c"]
    assert kwargs == {"text": True, "timeout": 12}
    code = command[-1]
    ast.parse(code)
    assert "connect_args={'connect_timeout':3}" in code
    assert "with e.begin() as c:" in code
    assert code.index("SET TRANSACTION READ ONLY") < code.index("SET LOCAL statement_timeout='5s'") < code.index("SELECT version_num")
    assert code.endswith("e.dispose()")


def processing_and_exec_timeout():
    ns, calls, _process = environment(output="0\n")
    assert ns["processing_count"]() == 0
    assert "SELECT count(*) FROM outbox_events WHERE status='PROCESSING'" in calls["check_output"][0][0][-1]
    ns, _calls, _process = environment(output_error=subprocess.TimeoutExpired("synthetic-docker-exec", 12))
    raises(subprocess.TimeoutExpired, ns["schema"])


def bounded_inspect():
    ns, calls, _process = environment(output='[{"Id":"synthetic"}]')
    assert ns["inspect"]("synthetic-worker")["Id"] == "synthetic"
    assert calls["check_output"][0][1] == {"timeout": 10}


record("successful_guard_starts_separate_session", successful_guard)
record("outer_timeout_cleans_only_fake_session_and_withholds_rollback", outer_timeout)
record("missing_session_is_safe_but_still_uncertain", lambda: outer_timeout(True))
record("inner_guard_timeout_exit1_withholds_rollback", inner_timeout_exit_one)
record("timeout_cleanup_failure_withholds_rollback", timeout_cleanup_failure_still_withholds_rollback)
record("unexpected_wait_error_withholds_rollback", unexpected_wait_error_still_withholds_rollback)
record("completed_switch_postcondition_failure_uses_guarded_rollback", completed_switch_postcondition_failure)
record("uncertain_rollback_not_reported_success", uncertain_rollback_stays_failed)
record("DB_query_readonly_connect3_statement5_exec12", readonly_query)
record("processing_count_and_exec_timeout_propagate", processing_and_exec_timeout)
record("inspect_timeout10", bounded_inspect)
print(json.dumps({
    "source": str(SOURCE), "source_sha256": EXPECTED,
    "scope": "Actual AST-selected function/except bodies with inert subprocess/os/filesystem substitutes; no deploy module top-level, Docker, DB, network, or real signal executed",
    "passed": len(results), "failed": 0, "checks": results,
}, indent=2))
