import importlib
import json
import pathlib
import sys
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sample = importlib.import_module("collect_im_runtime_sample")


class RuntimeLogTest(unittest.TestCase):
    def test_synapse_status_before_request_is_counted(self):
        result = sample.summarize_logs(
            [
                "INFO - GET-17 - Processed request: 30.001sec/0.001sec (0.0sec,0.0sec) "
                '12B 200 "GET /_matrix/client/v3/sync?timeout=30000&since=SECRET HTTP/1.1" '
                '"Synthetic" [0 dbevts]',
            ]
        )
        self.assertEqual(result["http_buckets"].get("sync:200", 0), 1)

    def test_route_category_uses_path_not_sensitive_query_values(self):
        result = sample.summarize_logs(
            [
                'INFO: 127.0.0.1 - "GET /unknown?next=recovery&token=SECRET HTTP/1.1" 401 Unauthorized',
            ]
        )
        self.assertEqual(result["http_buckets"].get("other:401", 0), 1)
        self.assertNotIn("SECRET", json.dumps(result))

    def test_mixed_formats_have_conserved_line_and_request_denominators(self):
        lines = [
            "GET-1 - Received request: GET /_matrix/client/v3/sync?timeout=30000&access_token=SECRET",
            'GET-1 - Processed request: 30.001sec/0.001sec 12B 200 "GET /_matrix/client/v3/sync?timeout=30000 HTTP/1.1" "UA" [0 dbevts]',
            "GET-2 - Received request: GET /_matrix/client/v3/sync?timeout=30000",
            'INFO: "POST /api/v1/auth/matrix-recovery-authorize HTTP/1.1" 503 Service Unavailable',
            'INFO httpx: HTTP Request: POST https://provider.invalid/v2/PRIVATE_APP/push/single/cid "HTTP/1.1 200 OK"',
            '"GET /health?token=SECRET HTTP/1.1" 401 12',
            '"GET /unknown/CID_SECRET HTTP/1.1" -',
            "Traceback (most recent call last):",
            "arbitrary sensitive BODY_SECRET",
            "",
        ]
        result = sample.summarize_logs(lines)
        self.assertEqual(result["log_lines"], len(lines))
        self.assertEqual(sum(result["line_buckets"].values()), len(lines))
        self.assertEqual(result["http_completed"], 4)
        self.assertEqual(sum(result["http_buckets"].values()), 4)
        self.assertEqual(result["started_request_records"], 2)
        self.assertEqual(result["completed_with_observed_start"], 1)
        self.assertEqual(result["started_without_observed_completion"], 1)
        self.assertEqual(result["completed_without_observed_start"], 3)
        self.assertEqual(result["http_without_completion_status"], 1)
        self.assertEqual(result["idle_sync_30s_completed"], 1)
        self.assertEqual(result["traceback_headers"], 1)
        self.assertEqual(result["line_buckets"]["unmatched"], 2)
        self.assertEqual(result["http_buckets"]["recovery_route:503"], 1)
        self.assertEqual(result["http_buckets"]["provider_push_http:200"], 1)
        rendered = json.dumps(result)
        for sensitive in [
            "SECRET",
            "PRIVATE_APP",
            "GET-1",
            "BODY_",
            "https:",
            "/_matrix",
            "device_received",
        ]:
            self.assertNotIn(sensitive, rendered)

    def test_long_sync_is_idle_only_with_zero_events_and_timeout_evidence(self):
        result = sample.summarize_logs(
            [
                'Processed request: 30.002sec/0sec 1B 200 "GET /_matrix/client/v3/sync?timeout=30000 HTTP/1.1" [3 dbevts]',
                'Processed request: 30.002sec/0sec 1B 200 "GET /_matrix/client/v3/sync?timeout=30000 HTTP/1.1"',
                'Processed request: 1.002sec/0sec 1B 200 "GET /_matrix/client/v3/sync?timeout=30000 HTTP/1.1" [0 dbevts]',
            ]
        )
        self.assertEqual(result["http_completed"], 3)
        self.assertEqual(result["idle_sync_30s_completed"], 0)

    def test_duplicate_start_ids_and_window_edges_do_not_lose_requests(self):
        result = sample.summarize_logs(
            [
                "GET-3 Received request: GET /health",
                "GET-3 Received request: GET /health",
                'GET-3 Processed request: 0.01sec 1B 200 "GET /health HTTP/1.1"',
                'GET-4 Processed request: 0.01sec 1B 200 "GET /health HTTP/1.1"',
            ]
        )
        self.assertEqual(result["started_request_records"], 2)
        self.assertEqual(result["completed_with_observed_start"], 1)
        self.assertEqual(result["started_without_observed_completion"], 1)
        self.assertEqual(result["completed_without_observed_start"], 1)

    def test_tail_byte_partial_and_unknown_rows_are_explicit(self):
        result = sample.summarize_logs(
            ["unknown", "partial SECRET"],
            tail_limit=2,
            byte_truncated=True,
            partial_last_line=True,
        )
        self.assertEqual(sum(result["line_buckets"].values()), 2)
        self.assertEqual(result["line_buckets"]["partial_line"], 1)
        self.assertEqual(result["line_buckets"]["unmatched"], 1)
        self.assertTrue(result["truncation"]["tail_limit_reached"])
        self.assertTrue(result["truncation"]["byte_limit_reached"])


class RuntimeCollectionTest(unittest.TestCase):
    def test_bounded_process_limits_bytes_and_timeout_without_error_text(self):
        captured = sample.run_bounded(
            [sys.executable, "-c", 'print("SECRET" * 10000)'], max_bytes=128, timeout=2
        )
        self.assertLessEqual(len(captured.data), 128)
        self.assertTrue(captured.byte_limit_reached)
        started = time.monotonic()
        captured = sample.run_bounded(
            [sys.executable, "-c", "import time; time.sleep(10)"],
            max_bytes=128,
            timeout=0.1,
        )
        self.assertEqual(captured.error, "timeout")
        self.assertLess(time.monotonic() - started, 3)

    def test_inspect_and_stats_allow_only_fixed_fields(self):
        state = sample.sanitize_inspect(
            {
                "image": "sha256:" + "a" * 64,
                "status": "running",
                "health": "healthy",
                "restart_count": 2,
                "Env": ["TOKEN=SECRET"],
                "Name": "CID_SECRET",
            }
        )
        self.assertEqual(state["restart_count"], 2)
        self.assertNotIn("SECRET", json.dumps(state))
        resources = sample.sanitize_stats(
            {
                "cpu": "12.3%",
                "memory": "2MiB / 1GiB",
                "memory_percent": "0.2%",
                "pids": "5",
                "Name": "SECRET",
            }
        )
        self.assertEqual(resources["memory_bytes"], 2 * 1024 * 1024)
        self.assertEqual(resources["pids"], 5)
        self.assertNotIn("SECRET", json.dumps(resources))
        self.assertIsNone(sample.sanitize_inspect({"image": "SECRET"})["image"])

    def test_collection_uses_fixed_window_and_only_read_only_docker_commands(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(argv)
            if argv[1] == "logs":
                return sample.CommandResult(b'"GET /health HTTP/1.1" 200 0\n')
            if argv[1] == "inspect":
                return sample.CommandResult(
                    b'{"image":"sha256:'
                    + b"a" * 64
                    + b'","status":"running","health":"healthy","restart_count":0}'
                )
            return sample.CommandResult(
                b'{"cpu":"1%","memory":"1MiB / 1GiB","memory_percent":"0.1%","pids":"2"}'
            )

        result = sample.collect_sample(window_seconds=60, runner=runner)
        self.assertEqual(len(result["services"]), 4)
        self.assertEqual(len(calls), 12)
        self.assertEqual({call[1] for call in calls}, {"inspect", "logs", "stats"})
        for call in calls:
            self.assertNotIn("--follow", call)
            if call[1] == "logs":
                self.assertIn("--since", call)
                self.assertIn("--until", call)
                self.assertIn("--tail", call)

    def test_failed_sample_is_missing_not_zero_success_and_never_echoes_error(self):
        def runner(argv, **kwargs):
            return sample.CommandResult(
                b"SECRET CID https://private.invalid/", error="command_failed"
            )

        result = sample.collect_sample(window_seconds=60, runner=runner)
        for service in result["services"]:
            self.assertEqual(service["logs"]["error"], "command_failed")
            self.assertIsNone(service["logs"]["summary"])
        self.assertNotIn("SECRET", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
