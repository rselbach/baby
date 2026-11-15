"""Run rotate-feed-key.sh against stand-in swift, tool, and gh commands."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
NEW_KEY = "N" * 43 + "="


class RotateFeedKeyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="baby-rotate-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.checkout = self.root / "checkout"
        for name in ("scripts/rotate-feed-key.sh", "Sources/BabyUpdate/Feed.swift",
                     "site/site.js"):
            (self.checkout / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / name, self.checkout / name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        tools = self.root / "tools"
        tools.mkdir()
        self.command(self.bin / "swift", f'''
case "$*" in
  *--show-bin-path*) echo "{tools}" ;;
esac
''')
        self.command(tools / "baby-update-tool", f'''
[ "$1" = generate-key ] && [ "$2" = --seed-out ] || exit 2
printf 'c2VlZA==\\n' >"$3"
echo "{NEW_KEY}"
''')
        self.secret = self.root / "secret"
        self.command(self.bin / "gh", f'''
case "$1" in
  auth) exit 0 ;;
  secret) echo "$*" >"{self.secret}.args"; cat >"{self.secret}" ;;
  *) exit 2 ;;
esac
''')

    def command(self, path, body):
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def run_script(self, *args):
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}")
        return subprocess.run(
            ["/bin/bash", str(self.checkout / "scripts/rotate-feed-key.sh"), *args],
            capture_output=True, text=True, env=env, timeout=30,
        )

    def test_rotates_the_app_site_and_secret(self):
        seed = self.root / "seed.txt"
        result = self.run_script(str(seed))
        self.assertEqual(result.returncode, 0, result.stderr)
        feed = (self.checkout / "Sources/BabyUpdate/Feed.swift").read_text()
        site = (self.checkout / "site/site.js").read_text()
        self.assertIn(f'  public static let publicKeys = ["{NEW_KEY}"]\n', feed)
        self.assertIn("public static let legacyPublicKey = ", feed)
        self.assertIn(f'  const PUBLIC_KEY = "{NEW_KEY}";\n', site)
        self.assertEqual(self.secret.read_text(), "c2VlZA==\n")
        self.assertEqual(Path(f"{self.secret}.args").read_text().strip(),
                         "secret set BABY_FEED_SIGNING_KEY")
        self.assertEqual(seed.read_text(), "c2VlZA==\n")

        # a second rotation would strand builds that trust the first new key
        again = self.run_script(str(self.root / "again.txt"))
        self.assertNotEqual(again.returncode, 0)
        self.assertIn("already trusts", again.stderr)

    def test_refuses_to_overwrite_a_seed_file(self):
        seed = self.root / "seed.txt"
        seed.write_text("keep me")
        result = self.run_script(str(seed))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(seed.read_text(), "keep me")
        self.assertFalse(self.secret.exists())


if __name__ == "__main__":
    unittest.main()
