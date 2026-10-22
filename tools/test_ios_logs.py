#!/usr/bin/env python3
"""用可控宿主读取器验证命令行采集，不重启真实 iPhone App。"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "skills/ios-app-logs/scripts/ios_logs.py"
FAKE = r'''#!/usr/bin/env python3
import json, os, signal, sys, time
from pathlib import Path
mode = os.environ.get("LUMEN_TEST_MODE", "streams")
if "--json-output" in sys.argv:
    target = sys.argv[sys.argv.index("--json-output") + 1]
    if "apps" in sys.argv:
        result = {"apps": [{"bundleIdentifier": "com.test.app", "name": "Test"}]}
    else:
        result = {"devices": [{"hardwareProperties": {"platform": "iOS", "udid": "test-device"}, "deviceProperties": {"name": "测试设备"}, "connectionProperties": {"tunnelState": "connected"}}]}
    Path(target).write_text(json.dumps({"result": result}))
    sys.exit(0)
assert "--quiet" in sys.argv and "--console" in sys.argv and "--terminate-existing" in sys.argv
if mode == "empty":
    sys.exit(0)
if mode == "failure":
    os.write(2, b"launch failed")
    sys.exit(7)
if mode == "limit":
    os.write(1, b"A" * 65536)
else:
    raw = "多行输出\n第一行\n尾部未换行".encode()
    for byte in raw:
        os.write(1, bytes([byte]))
    os.write(2, "标准错误尾部".encode())
if mode == "natural":
    sys.exit(0)
# 捕获普通信号就留下证据；正确实现应仅 SIGKILL 此读取器。
signal.signal(signal.SIGTERM, lambda *_: Path(os.environ["LUMEN_TEST_SIGNAL"]).write_text("forwarded"))
while True:
    time.sleep(0.02)
'''


class ScriptCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        tool = self.root / "xcrun"
        tool.write_text(FAKE.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1))
        tool.chmod(0o700)
        self.environment = dict(os.environ, PATH=f"{self.root}:{os.environ['PATH']}", LUMEN_TEST_SIGNAL=str(self.root / "signal"))

    def tearDown(self):
        self.temporary.cleanup()

    def command(self, *arguments):
        return [sys.executable, str(SCRIPT), *arguments]

    def capture(self, mode="streams", extra=()):
        output = self.root / f"capture-{mode}"
        args = ["capture", "--device", "test", "--bundle-id", "com.test.app", "--restart-app", "--seconds", "3", "--output", str(output), *extra]
        result = subprocess.run(self.command(*args), env=dict(self.environment, LUMEN_TEST_MODE=mode), capture_output=True, timeout=6)
        return result, output, json.loads(result.stdout)

    def test_discovery_uses_official_json_and_app_filter(self):
        result = subprocess.run(self.command("devices"), env=self.environment, capture_output=True, timeout=6)
        self.assertTrue(json.loads(result.stdout)["devices"][0]["connected"])
        result = subprocess.run(self.command("apps", "--device", "test", "--match", "com.test"), env=self.environment, capture_output=True, timeout=6)
        self.assertEqual(json.loads(result.stdout)["apps"][0]["bundle_id"], "com.test.app")

    def test_both_streams_exact_utf8_and_timeout_does_not_forward_signal(self):
        result, output, summary = self.capture()
        self.assertEqual(result.returncode, 0)
        self.assertEqual((output / "stdout.log").read_text(), "多行输出\n第一行\n尾部未换行")
        self.assertEqual((output / "stderr.log").read_text(), "标准错误尾部")
        self.assertEqual(summary["stop_reason"], "duration")
        self.assertEqual(summary["reader_return_code"], -signal.SIGKILL)
        self.assertTrue(summary["drain_complete"])
        self.assertFalse((self.root / "signal").exists())
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        self.assertEqual((output / "stdout.log").stat().st_mode & 0o777, 0o600)

    def test_natural_exit_and_failure_and_no_output_are_distinct(self):
        result, _, summary = self.capture("natural")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(summary["stop_reason"], "source_ended")
        result, _, summary = self.capture("failure")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(summary["reader_return_code"], 7)
        result, _, summary = self.capture("empty")
        self.assertEqual(result.returncode, 3)
        self.assertFalse(summary["received_output"])

    def test_combined_size_limit_is_enforced(self):
        result, output, summary = self.capture("limit", ["--max-mib", "0.001"])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(summary["stop_reason"], "size_limit")
        self.assertTrue(summary["truncated"])
        self.assertEqual(sum((output / name).stat().st_size for name in ["stdout.log", "stderr.log"]), int(0.001 * 1024 * 1024))

    def test_restart_required_and_existing_output_is_preserved(self):
        args = ["capture", "--device", "test", "--bundle-id", "com.test.app", "--output", str(self.root)]
        result = subprocess.run(self.command(*args), env=self.environment, capture_output=True, timeout=6)
        self.assertEqual(result.returncode, 2)
        marker = self.root / "keep.log"
        marker.write_text("保留")
        result = subprocess.run(self.command(*args, "--restart-app"), env=self.environment, capture_output=True, timeout=6)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(marker.read_text(), "保留")

    def test_invalid_limits_are_rejected_before_capture(self):
        for option, value in [("--seconds", "nan"), ("--seconds", "0"), ("--seconds", "3601"), ("--max-mib", "inf"), ("--max-mib", "0.0000001"), ("--max-mib", "1025")]:
            output = self.root / "invalid"
            result = subprocess.run(self.command("capture", "--device", "test", "--bundle-id", "com.test.app", "--restart-app", "--output", str(output), option, value), env=self.environment, capture_output=True, timeout=6)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(output.exists())

    def test_parent_interruption_kills_only_reader(self):
        output = self.root / "interrupt"
        child = subprocess.Popen(self.command("capture", "--device", "test", "--bundle-id", "com.test.app", "--restart-app", "--seconds", "30", "--output", str(output)), env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while not (output / "stderr.log").exists() or (output / "stderr.log").stat().st_size == 0:
                if child.poll() is not None or time.monotonic() > deadline:
                    self.fail("读取器未就绪")
                time.sleep(0.01)
            child.send_signal(signal.SIGTERM)
            stdout, _ = child.communicate(timeout=5)
            summary = json.loads(stdout)
            self.assertEqual(child.returncode, 0)
            self.assertEqual(summary["stop_reason"], "interrupted")
            self.assertEqual(summary["reader_return_code"], -signal.SIGKILL)
            self.assertFalse((self.root / "signal").exists())
        finally:
            if child.poll() is None:
                child.kill()
                child.communicate()


if __name__ == "__main__":
    unittest.main()
