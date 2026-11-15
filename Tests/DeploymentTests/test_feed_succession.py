"""Check the deploy-time feed succession rules against Feed.swift's."""

import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/check-feed-succession.py"


def release(**changes):
    value = {
        "schema": 1, "app": "com.rselbach.baby", "channel": "stable",
        "version": "1.2.0", "build": 1002000, "published_at": "2026-11-03T12:00:00Z",
        "artifacts": [{"kind": "app-zip", "sha256": "ab" * 32}],
    }
    value.update(changes)
    return {key: item for key, item in value.items() if item is not None}


class SuccessionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="baby-feed-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def write(self, name, payload, signature="c2ln"):
        path = self.root / name
        body = {"payload": base64.b64encode(json.dumps(payload).encode()).decode(),
                "signature": signature}
        path.write_text(json.dumps(body))
        return path

    def check(self, live, new):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.write("live.json", live)),
             str(self.write("new.json", new, signature="b3RoZXI="))],
            capture_output=True, text=True, timeout=10,
        )
        return result.returncode == 0, result.stderr

    def assertAllowed(self, live, new):
        allowed, stderr = self.check(live, new)
        self.assertTrue(allowed, stderr)

    def assertRefused(self, live, new):
        allowed, _ = self.check(live, new)
        self.assertFalse(allowed)

    def test_allows_the_same_release(self):
        self.assertAllowed(release(), release())

    def test_allows_newer_builds_and_versions(self):
        self.assertAllowed(release(), release(version="1.2.1", build=1002001))
        self.assertAllowed(release(), release(build=1002001))

    def test_refuses_older_builds_and_versions(self):
        self.assertRefused(release(), release(build=1001999))
        self.assertRefused(release(), release(version="1.1.9", build=1002001))

    def test_allows_only_later_expiry_for_the_same_build(self):
        live = release(expires_at="2027-01-01T00:00:00Z")
        self.assertAllowed(release(), live)
        self.assertAllowed(live, release(expires_at="2027-02-01T00:00:00.500Z"))
        self.assertRefused(live, release(expires_at="2026-12-31T00:00:00Z"))
        self.assertRefused(live, release())
        changed = release(expires_at="2027-02-01T00:00:00Z")
        changed["artifacts"] = [{"kind": "app-zip", "sha256": "cd" * 32}]
        self.assertRefused(live, changed)


if __name__ == "__main__":
    unittest.main()
