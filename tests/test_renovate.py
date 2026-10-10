"""Repo-specific contract tests for renovate.json."""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FSDK_CONTAINERS = "https://github.com/projectbluefin/fsdk-containers"


class RenovateContractTests(unittest.TestCase):
    def test_runner_rule_keeps_ubuntu_24_04(self):
        rules = json.loads((ROOT / "renovate.json").read_text())["packageRules"]
        runner_rule = next(r for r in rules if r.get("matchDatasources") == ["github-runners"])
        self.assertEqual(runner_rule["allowedVersions"], r"/^24\.04(?:-arm)?$/")

    def test_fsdk_containers_junction_is_tracked_and_automerged(self):
        config = json.loads((ROOT / "renovate.json").read_text())
        # enabledManagers silently drops a custom manager that is not listed.
        self.assertIn("custom.regex", config["enabledManagers"])
        (manager,) = [m for m in config["customManagers"] if m["depNameTemplate"] == FSDK_CONTAINERS]
        pattern = re.compile(manager["matchStrings"][0].replace("(?<", "(?P<"))
        # bst source track writes git-describe refs (project.conf ref-format);
        # Renovate must match both forms and always write a plain sha.
        plain = re.sub(r"ref: \S+-g", "ref: ", (ROOT / "elements/fsdk-containers.bst").read_text())
        new = "0" * 40
        for junction in (plain, plain.replace("ref: ", "ref: v26.08.2-3-g")):
            match = pattern.search(junction)
            self.assertIsNotNone(match, "matchStrings no longer matches elements/fsdk-containers.bst")
            self.assertEqual(match["currentValue"], "main")
            self.assertRegex(match["currentDigest"], r"^[0-9a-f]{40}$")
            replaced = manager["autoReplaceStringTemplate"].replace("{{{newValue}}}", "main").replace("{{{newDigest}}}", new)
            self.assertEqual(pattern.search(junction.replace(match[0], replaced))[0], f"track: main\n    ref: {new}")
        rule = next(r for r in config["packageRules"] if r.get("matchDepNames") == [FSDK_CONTAINERS])
        self.assertLessEqual(
            {"automerge": True, "automergeType": "pr", "platformAutomerge": True, "ignoreTests": False, "minimumReleaseAge": None}.items(),
            rule.items(),
        )


if __name__ == "__main__":
    unittest.main()
