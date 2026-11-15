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

    def test_build_numbers_grow_with_the_version(self):
        script = Path(__file__).resolve().parents[2] / "scripts/build-number.sh"
        cases = {
            "1.2.2": "1002002", "0.0.1": "1", "1.10.0": "1010000",
            "999999.999.999": "999999999999",
            "01.2.3": None, "1.1000.0": None, "1.2": None, "1.2.3.4": None,
            "0.0.0": None, "v1.2.3": None, "": None,
        }
        for version, want in cases.items():
            with self.subTest(version=version):
                result = subprocess.run(
                    ["/bin/bash", str(script), version],
                    capture_output=True, text=True, timeout=10,
                )
                if want is None:
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), want)
        ordered = ["0.9.999", "1.0.0", "1.0.1", "1.1.0", "1.999.999", "2.0.0"]
        builds = [
            int(subprocess.run(["/bin/bash", str(script), v], capture_output=True,
                               text=True, check=True).stdout)
            for v in ordered
        ]
        self.assertEqual(builds, sorted(builds))
        self.assertEqual(len(set(builds)), len(builds))


if __name__ == "__main__":
    unittest.main()
