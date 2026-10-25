"""Check the numeric version the Makefile derives from ``VERSION``.

PAPPL publishes the version as four unsigned 16-bit integers next to the text
string. The Makefile maps ``VERSION`` onto those four numbers; these tests run
the real Makefile with ``make -n`` and require that the shipped ``VERSION``
yields four plain integers from 0 to 65535, that the date format maps to
year.month.day.revision, and that a version the mapping cannot convert stops
the build. They need GNU make and awk only.
"""
import os
from pathlib import Path
import re
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[1]
MAKE = os.environ.get("MAKE", "make")
DEFINE = re.compile(r"-DSYSTEM_VERSION_ARR_([0-3])=(\S+)")


def numeric_version(version):
    result = subprocess.run(
        [MAKE, "-s", "-n", "-B", "-C", str(REPO), f"VERSION={version}", "ps-printer-app.o"],
        capture_output=True,
        text=True,
        env={k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MFLAGS")},
    )
    return result, dict(DEFINE.findall(result.stdout))


class NumericVersionTest(unittest.TestCase):
    def test_shipped_version_is_four_16_bit_integers(self):
        version = (REPO / "VERSION").read_text().strip()
        result, fields = numeric_version(version)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(fields), ["0", "1", "2", "3"], result.stdout)
        for index, value in fields.items():
            with self.subTest(field=index):
                self.assertRegex(value, r"^[0-9]+$")
                self.assertLessEqual(int(value), 65535)

    def test_mapped_versions(self):
        cases = {
            "20240504-20": ["2024", "5", "4", "20"],
            "20241231-0": ["2024", "12", "31", "0"],
            "3.26.4-2": ["3", "26", "4", "2"],
            "1.0": ["1", "0", "0", "0"],
            "2": ["2", "0", "0", "0"],
        }
        for version, expected in cases.items():
            with self.subTest(version=version):
                result, fields = numeric_version(version)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([fields.get(str(i)) for i in range(4)], expected)

    def test_unconvertible_versions_stop_the_build(self):
        for version in ("20240504", "20241301-1", "20240500-1", "1.2.3.4",
                        "70000", "1.0-65536", "v1.0", "1.0 2", ""):
            with self.subTest(version=version):
                result, fields = numeric_version(version)
                if version == "":
                    # An empty VERSION leaves the C defaults in place.
                    self.assertEqual(fields, {})
                    continue
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("is neither", result.stderr)


if __name__ == "__main__":
    unittest.main()
