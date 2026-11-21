"""Check signing identity and authority lookup under pipefail."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
TEAM_ID = "LS8YD2TR79"
FIRST_SHA1 = "A" * 40
SECOND_SHA1 = "B" * 40


class SigningLookupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="baby-signing-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()

    def write_stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def run_function(self, script_name, func_name):
        source = (REPO / script_name).read_text()
        self.assertTrue(source.endswith('main "$@"\n'))
        harness = self.root / f"{func_name}.sh"
        harness.write_text(source.removesuffix('main "$@"\n') + f"{func_name}\n")
        env = {k: v for k, v in os.environ.items() if k != "SIGNING_IDENTITY"}
        env["PATH"] = f"{self.bin}:{os.environ['PATH']}"
        return subprocess.run(
            ["/bin/bash", str(harness)],
            capture_output=True, text=True, env=env, timeout=15,
        )

    def test_signing_identity_handles_zero_multiple_and_large_outputs(self):
        # 0 matches -> falls back to ad-hoc "-"
        self.write_stub("security", 'printf "     0 valid identities found\\n"\n')
        result = self.run_function("build.sh", "signing_identity")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "-")

        # Multiple matches -> first matching team SHA-1
        lines = [
            f'  1) {"0" * 40} "Apple Development: Troy Barnes (OTHER12345)"',
            f'  2) {FIRST_SHA1} "Developer ID Application: Troy Barnes ({TEAM_ID})"',
            f'  3) {SECOND_SHA1} "Developer ID Application: Greendale ({TEAM_ID})"',
            "     3 valid identities found",
        ]
        fixture = self.root / "identities.txt"
        fixture.write_text("\n".join(lines) + "\n")
        self.write_stub("security", f'cat "{fixture}"\n')
        result = self.run_function("build.sh", "signing_identity")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), FIRST_SHA1)

        # Large output (>256 KiB) would trigger SIGPIPE with head -n 1 under pipefail
        big_lines = [
            f'  1) {FIRST_SHA1} "Developer ID Application: Troy Barnes ({TEAM_ID})"',
        ] + [
            f'  {i}) {SECOND_SHA1} "Developer ID Application: Greendale Community College ({TEAM_ID})"'
            for i in range(2, 5002)
        ]
        fixture.write_text("\n".join(big_lines) + "\n")
        result = self.run_function("build.sh", "signing_identity")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), FIRST_SHA1)

    def test_app_authority_handles_zero_multiple_and_large_outputs(self):
        # 0 Authority lines (ad-hoc signature)
        self.write_stub("codesign", 'printf "Signature=adhoc\\n" >&2\n')
        result = self.run_function("release.sh", "app_authority")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

        # Multiple Authority lines -> first (leaf) authority
        fixture = self.root / "codesign.txt"
        fixture.write_text(
            "Executable=/tmp/Baby.app/Contents/MacOS/Baby\n"
            f"Authority=Developer ID Application: Troy Barnes ({TEAM_ID})\n"
            "Authority=Developer ID Certification Authority\n"
            "Authority=Apple Root CA\n"
        )
        self.write_stub("codesign", f'cat "{fixture}" >&2\n')
        result = self.run_function("release.sh", "app_authority")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.strip(),
            f"Developer ID Application: Troy Barnes ({TEAM_ID})",
        )

        # Large output (>256 KiB) would trigger SIGPIPE with head -n 1 under pipefail
        big_lines = [
            f"Authority=Developer ID Application: Troy Barnes ({TEAM_ID})",
        ] + [
            f"Authority=Greendale Community College Intermediate {i}"
            for i in range(5000)
        ]
        fixture.write_text("\n".join(big_lines) + "\n")
        result = self.run_function("release.sh", "app_authority")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.strip(),
            f"Developer ID Application: Troy Barnes ({TEAM_ID})",
        )

        # Upstream command failure still propagates under pipefail
        self.write_stub("codesign", "exit 17\n")
        result = self.run_function("release.sh", "app_authority")
        self.assertEqual(result.returncode, 17)


if __name__ == "__main__":
    unittest.main()
