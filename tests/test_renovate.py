"""Repo-specific contract tests for renovate.json."""

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class RenovateContractTests(unittest.TestCase):
    def test_runner_rule_keeps_ubuntu_24_04(self):
        rules = json.loads((ROOT / "renovate.json").read_text())["packageRules"]
        runner_rule = next(r for r in rules if r.get("matchDatasources") == ["github-runners"])
        self.assertEqual(runner_rule["allowedVersions"], r"/^24\.04(?:-arm)?$/")


if __name__ == "__main__":
    unittest.main()
