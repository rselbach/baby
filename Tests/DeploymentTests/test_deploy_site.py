"""Exercise publication, rollback, and serialization without a live server."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="baby-deploy-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.script = Path(__file__).resolve().parents[2] / "scripts/deploy-site-remote.sh"
        self.web = self.root / "web"
        self.old = self.web / "releases/release.old123"
        (self.old / "baby").mkdir(parents=True)
        self.current = self.web / "current"
        self.current.symlink_to(self.old)
        self.server = self.root / "server.conf"
        self.snippet = self.root / "snippet.conf"
        self.original_server = "server_name rselbach.com;\n"
        self.server.write_text(self.original_server)
        self.snippet.write_text("old snippet\n")
        self.files = ("index.html", "site.js", "icon.png", "awake.png")
        for name in self.files:
            (self.old / "baby" / name).write_text("old " + name)
        self.command("sudo", 'exec "$@"', shell=True)
        self.command("nginx", 'exit "${NGINX_STATUS:-0}"', shell=True)
        self.command("flock", "import fcntl, sys\nfcntl.flock(int(sys.argv[-1]), fcntl.LOCK_EX)")
        self.command("mv", "import os, sys\nos.replace(sys.argv[-2], sys.argv[-1])")
        self.command("systemctl", '''
import os
from pathlib import Path
root = Path(os.environ["TEST_ROOT"])
count = root / "reloads"
n = int(count.read_text()) + 1 if count.exists() else 1
count.write_text(str(n))
mode = os.environ.get("RELOAD_FAILURE", "")
raise SystemExit(1 if mode == "always" or mode == "once" and n == 1 else 0)
''')
        self.command("curl", '''
import os, sys, time
from pathlib import Path
from urllib.parse import urlparse
args = sys.argv[1:]
root = Path(os.environ["TEST_ROOT"])
if "-I" in args:
    print("Content-Security-Policy: connect-src https://rselbach.github.io")
    raise SystemExit(0)
if "-w" in args:
    print("https://rselbach.com/baby/", end="")
    raise SystemExit(0)
path = urlparse(args[-1]).path
if path == "/":
    raise SystemExit(0)
if os.environ.get("VERIFY_GATE"):
    (root / "verifying").touch()
    deadline = time.monotonic() + 10
    while not (root / "continue").exists():
        if time.monotonic() > deadline:
            raise SystemExit(2)
        time.sleep(0.02)
if os.environ.get("VERIFY_FAILURE"):
    raise SystemExit(1)
source = root / "web/current" / path.lstrip("/")
Path(args[args.index("-o") + 1]).write_bytes(source.read_bytes())
''')

    def command(self, name, body, shell=False):
        path = self.bin / name
        path.write_text(("#!/bin/bash" if shell else "#!" + sys.executable) + "\n" + body + "\n")
        path.chmod(0o755)

    def launch(self, label="new", **settings):
        upload = self.root / ("upload-" + label)
        (upload / "site").mkdir(parents=True)
        for name in self.files:
            (upload / "site" / name).write_text(label + " " + name)
        (upload / "nginx.conf").write_text(label + " snippet\n")
        environment = dict(os.environ, **settings)
        environment["PATH"] = str(self.bin) + os.pathsep + os.environ["PATH"]
        environment["TEST_ROOT"] = str(self.root)
        process = subprocess.Popen(
            ["/bin/bash", str(self.script), str(upload), str(self.web),
             str(self.snippet), str(self.server), "https://rselbach.com/baby/"],
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.addCleanup(self.stop, process)
        return process, upload

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.kill()
        process.communicate()

    def finish(self, process):
        stdout, stderr = process.communicate(timeout=15)
        return process.returncode, stdout + stderr

    def assert_restored(self, **settings):
        process, upload = self.launch(**settings)
        status, output = self.finish(process)
        self.assertNotEqual(status, 0, output)
        self.assertEqual(self.server.read_text(), self.original_server)
        self.assertEqual(self.snippet.read_text(), "old snippet\n")
        self.assertEqual(self.current.resolve(), self.old)
        self.assertEqual(list((self.web / "releases").iterdir()), [self.old])
        self.assertFalse(upload.exists())

    def test_invalid_nginx_restores_config_without_switching_site(self):
        self.assert_restored(NGINX_STATUS="1")

    def test_missing_server_block_restores_configuration(self):
        self.original_server = "server_name greendale.example;\n"
        self.server.write_text(self.original_server)
        self.assert_restored()

    def test_reload_failure_restores_files_and_running_configuration(self):
        self.assert_restored(RELOAD_FAILURE="once")
        self.assertEqual((self.root / "reloads").read_text(), "2")

    def test_verification_failure_restores_files_and_running_configuration(self):
        self.assert_restored(VERIFY_FAILURE="1")
        self.assertEqual((self.root / "reloads").read_text(), "2")

    def test_first_deployment_failure_removes_new_pointer_and_snippet(self):
        self.current.unlink()
        self.snippet.unlink()
        process, upload = self.launch(VERIFY_FAILURE="1")
        status, output = self.finish(process)
        self.assertNotEqual(status, 0, output)
        self.assertFalse(self.current.is_symlink())
        self.assertFalse(self.snippet.exists())
        self.assertEqual(self.server.read_text(), self.original_server)
        self.assertFalse(upload.exists())

    def test_failed_rollback_preserves_recovery_files(self):
        process, upload = self.launch(RELOAD_FAILURE="always")
        status, output = self.finish(process)
        self.assertNotEqual(status, 0, output)
        self.assertIn("rollback failed", output)
        self.assertEqual((upload / "server.conf").read_text(), self.original_server)
        self.assertEqual((upload / "snippet.conf").read_text(), "old snippet\n")
        self.assertEqual(len(list((self.web / "releases").iterdir())), 2)

    def test_regular_directory_is_not_replaced(self):
        self.current.unlink()
        self.current.mkdir()
        sentinel = self.current / "troy"
        sentinel.write_text("Barnes")
        process, _ = self.launch()
        status, output = self.finish(process)
        self.assertNotEqual(status, 0, output)
        self.assertEqual(sentinel.read_text(), "Barnes")

    def test_repeated_success_publishes_complete_snapshots(self):
        previous = self.old
        for label in ("first", "second"):
            process, upload = self.launch(label)
            status, output = self.finish(process)
            self.assertEqual(status, 0, output)
            for name in self.files:
                self.assertEqual((self.current / "baby" / name).read_text(), label + " " + name)
            self.assertEqual(self.snippet.read_text(), label + " snippet\n")
            self.assertEqual(self.server.read_text().count(f"include {self.snippet};"), 1)
            self.assertFalse(previous.exists())
            self.assertFalse(upload.exists())
            previous = self.current.resolve()

    def test_failed_deployment_cannot_roll_back_concurrent_success(self):
        first, _ = self.launch("first", VERIFY_GATE="1", VERIFY_FAILURE="1")
        deadline = time.monotonic() + 10
        while not (self.root / "verifying").exists():
            self.assertIsNone(first.poll())
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.02)
        second, _ = self.launch("second")
        time.sleep(0.2)
        self.assertIsNone(second.poll())
        self.assertEqual((self.current / "baby/index.html").read_text(), "first index.html")
        (self.root / "continue").touch()
        self.assertNotEqual(self.finish(first)[0], 0)
        status, output = self.finish(second)
        self.assertEqual(status, 0, output)
        self.assertEqual((self.current / "baby/index.html").read_text(), "second index.html")
        self.assertEqual(self.snippet.read_text(), "second snippet\n")


if __name__ == "__main__":
    unittest.main()
