"""Check the release version boundary without building an app for each case."""

from pathlib import Path
import subprocess
import tempfile
import unittest


class VersionTests(unittest.TestCase):
    def test_numeric_versions_match_the_feed_contract(self):
        source = (Path(__file__).resolve().parents[2] / "build.sh").read_text()
        source = source.removesuffix('main "$@"\n') + 'valid_version "$1"\n'
        cases = {
            "1": True, "1.2": True, "1.2.3": True, "0.0.0": True,
            "01.002.3": True, "9223372036854775807": True,
            "0009223372036854775807.0": True, "0" * 64: True,
            "1.2.0-beta": False, "1.2.0+build": False, "1.2.3.4": False,
            "1..2": False, "": False, "+14": False, "1.-0": False,
            "9223372036854775808": False, "0" * 65: False, "١٤": False,
        }
        with tempfile.TemporaryDirectory(prefix="baby-build-tests-") as directory:
            script = Path(directory) / "versions.sh"
            script.write_text(source)
            for version, want in cases.items():
                with self.subTest(version=version):
                    result = subprocess.run(
                        ["/bin/bash", str(script), version],
                        capture_output=True, text=True, timeout=10,
                    )
                    self.assertEqual(result.returncode == 0, want, result.stderr)


if __name__ == "__main__":
    unittest.main()
