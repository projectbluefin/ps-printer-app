"""Exercise the real metadata checker against fixtures that disagree.

These are metadata tests. They run ``scripts/verify-fsdk-metadata.py`` exactly
as promotion runs it, over committed fixture trees and committed index
documents. They say nothing about OCI printing or about physical paper output.

The case that matters is ``stale-labels``: a commit bumps the pinned
freedesktop-sdk junction and leaves the OCI FSDK labels naming the previous
release. That tree must be refused, with a diagnostic that names both sides, so
a promotion that would advance ``stable`` onto inconsistent metadata stops
before it writes anything.
"""
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/verify-fsdk-metadata.py"
FIXTURES = REPO / "tests/fixtures/fsdk-metadata"
WORKFLOW = REPO / ".github/workflows/promote-stable.yml"

FSDK_VERSION = "26.08rc.1"
FSDK_REF = "e076d4978ee6945763486f6ebd755d189460e4e7"
BUMPED_VERSION = "26.08rc.2"
BUMPED_REF = "3b1c9f0a2d4e5b6c7d8e9f0a1b2c3d4e5f607182"


def run(*args, stdin=None, env=None):
    """Run the checker the way CI does, as a separate process."""
    environment = {**os.environ, "SKOPEO": "skopeo-not-installed"}
    environment.update(env or {})
    result = subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        input=stdin,
        env=environment,
        text=True,
        capture_output=True,
    )
    return result


def graph_root(name):
    return str(FIXTURES / name)


def fixture(name):
    return str(FIXTURES / name)


class SourceConsistencyTest(unittest.TestCase):
    """The graph against itself: the junction pin and the image labels."""

    def test_a_consistent_graph_passes(self):
        result = run("--graph-root", graph_root("consistent"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OK:", result.stdout)
        self.assertIn(FSDK_VERSION, result.stdout)
        self.assertIn(FSDK_REF, result.stdout)
        self.assertEqual(result.stderr, "")

    def test_stale_labels_fail_with_a_diagnostic(self):
        # The fixture for this issue: the junction moved, the labels did not.
        result = run("--graph-root", graph_root("stale-labels"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL:", result.stderr)
        # Both sides of the disagreement are named, so the diagnostic is
        # actionable without re-reading the files by hand.
        self.assertIn("io.projectbluefin.fsdk.version", result.stderr)
        self.assertIn(BUMPED_VERSION, result.stderr)
        self.assertIn(FSDK_VERSION, result.stderr)
        self.assertIn("io.projectbluefin.fsdk.ref", result.stderr)
        self.assertIn(BUMPED_REF, result.stderr)
        self.assertIn(FSDK_REF, result.stderr)
        self.assertIn("elements/oci/ps-printer-app.bst", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_a_repin_on_the_same_release_line_is_caught(self):
        # Same point release, different commit. A comparison that only looked at
        # the version would pass this tree.
        other = "9a8b7c6d5e4f30211fee0dd9cc8bb7aa6699a5b4"
        result = run("--graph-root", graph_root("mismatched-ref"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("io.projectbluefin.fsdk.ref", result.stderr)
        self.assertIn(other, result.stderr)
        self.assertNotIn("io.projectbluefin.fsdk.version", result.stderr)

    def test_an_unpinned_junction_fails_closed(self):
        result = run("--graph-root", graph_root("unpinned"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("no 'ref: freedesktop-sdk-", result.stderr)

    def test_a_missing_junction_fails_closed(self):
        result = run("--graph-root", graph_root("missing-junction"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("elements/freedesktop-sdk.bst does not exist", result.stderr)

    def test_a_missing_oci_element_fails_closed(self):
        result = run("--graph-root", graph_root("missing-oci"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("elements/oci/ps-printer-app.bst does not exist", result.stderr)

    def test_a_graph_that_omits_the_labels_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "elements/oci").mkdir(parents=True)
            (root / "elements/freedesktop-sdk.bst").write_text(
                (FIXTURES / "consistent/elements/freedesktop-sdk.bst").read_text()
            )
            (root / "elements/oci/ps-printer-app.bst").write_text(
                "kind: script\nconfig:\n  commands:\n    - build-oci\n"
            )
            result = run("--graph-root", str(root))
            self.assertEqual(result.returncode, 1)
            self.assertIn("does not set the io.projectbluefin.fsdk.version label", result.stderr)


class IndexMetadataTest(unittest.TestCase):
    """The graph against the metadata the published index carries."""

    def test_matching_index_metadata_passes(self):
        result = run("--graph-root", graph_root("consistent"), "--index", fixture("index-consistent.json"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("index annotations", result.stdout)

    def test_mismatched_index_metadata_fails_with_a_diagnostic(self):
        # The graph was bumped; the published index still describes the old pin.
        result = run(
            "--graph-root", graph_root("stale-labels"), "--index", fixture("index-stale-labels.json")
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL: FSDK metadata mismatch", result.stderr)
        self.assertIn("io.projectbluefin.fsdk.version", result.stderr)
        self.assertIn("io.projectbluefin.fsdk.ref", result.stderr)
        self.assertIn(fixture("index-stale-labels.json"), result.stderr)

    def test_an_index_without_annotations_fails_closed(self):
        result = run(
            "--graph-root", graph_root("consistent"), "--index", fixture("index-no-annotations.json")
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("carries no 'annotations' object", result.stderr)

    def test_an_index_that_drops_one_fsdk_label_fails_closed(self):
        result = run(
            "--graph-root",
            graph_root("consistent"),
            "--index",
            fixture("index-missing-fsdk-ref.json"),
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("io.projectbluefin.fsdk.ref is absent", result.stderr)

    def test_an_image_manifest_is_not_accepted_as_an_index(self):
        # An image manifest also carries annotations. Accepting it would skip
        # the index, which is where the FSDK labels are easiest to drop.
        result = run(
            "--graph-root", graph_root("consistent"), "--index", fixture("index-manifest.json")
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("no 'manifests' list", result.stderr)

    def test_index_metadata_is_read_from_standard_input(self):
        result = run(
            "--graph-root",
            graph_root("consistent"),
            "--index",
            "-",
            stdin=Path(fixture("index-consistent.json")).read_text(),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("standard input", result.stdout)

    def test_multiarch_is_required_only_when_asked(self):
        single = fixture("index-single-arch.json")
        permissive = run("--graph-root", graph_root("consistent"), "--index", single)
        self.assertEqual(permissive.returncode, 0, permissive.stderr)

        strict = run(
            "--graph-root", graph_root("consistent"), "--index", single, "--require-multiarch"
        )
        self.assertEqual(strict.returncode, 1)
        self.assertIn("missing arm64", strict.stderr)

    def test_a_matching_multiarch_index_passes_the_strict_check(self):
        result = run(
            "--graph-root",
            graph_root("consistent"),
            "--index",
            fixture("index-consistent.json"),
            "--require-multiarch",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_application_version_is_compared_when_given(self):
        matching = run(
            "--graph-root",
            graph_root("consistent"),
            "--index",
            fixture("index-consistent.json"),
            "--app-version",
            "20240504-20",
        )
        self.assertEqual(matching.returncode, 0, matching.stderr)

        stale = run(
            "--graph-root",
            graph_root("consistent"),
            "--index",
            fixture("index-consistent.json"),
            "--app-version",
            "20240504-21",
        )
        self.assertEqual(stale.returncode, 1)
        self.assertIn("org.opencontainers.image.version", stale.stderr)

    def test_index_and_index_ref_are_mutually_exclusive(self):
        result = run(
            "--graph-root",
            graph_root("consistent"),
            "--index",
            fixture("index-consistent.json"),
            "--index-ref",
            "docker://example.invalid/ps-printer-app:test",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("mutually exclusive", result.stderr)


class RegistryTest(unittest.TestCase):
    """A registry lookup that fails must never be read as agreement."""

    def stub_skopeo(self, directory, body, exit_code=0):
        stub = Path(directory) / "skopeo"
        stub.write_text("#!/bin/sh\ncat <<'EOF'\n%s\nEOF\nexit %d\n" % (body, exit_code))
        stub.chmod(0o755)
        return str(stub)

    def test_an_unreachable_registry_is_fatal(self):
        with tempfile.TemporaryDirectory() as temp:
            # A lookup that fails with a network error, not a missing manifest.
            stub = self.stub_skopeo(temp, "dial tcp: lookup example.invalid: no such host", 1)
            result = run(
                "--graph-root",
                graph_root("consistent"),
                "--index-ref",
                "docker://example.invalid/ps-printer-app:test",
                env={"SKOPEO": stub},
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("cannot read index metadata", result.stderr)
            self.assertIn("no such host", result.stderr)

    def test_a_missing_subject_never_passes(self):
        with tempfile.TemporaryDirectory() as temp:
            stub = self.stub_skopeo(temp, "manifest unknown", 1)
            result = run(
                "--graph-root",
                graph_root("consistent"),
                "--index-ref",
                "docker://example.invalid/ps-printer-app:test",
                env={"SKOPEO": stub},
            )
            self.assertEqual(result.returncode, 1)

    def test_registry_metadata_is_compared_when_it_resolves(self):
        with tempfile.TemporaryDirectory() as temp:
            stub = self.stub_skopeo(temp, Path(fixture("index-consistent.json")).read_text())
            result = run(
                "--graph-root",
                graph_root("consistent"),
                "--index-ref",
                "docker://example.invalid/ps-printer-app:test",
                env={"SKOPEO": stub},
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            # The same resolver, now serving an index published before the graph
            # was bumped. The comparison is what refuses it, not the lookup.
            mismatched = self.stub_skopeo(
                temp, Path(fixture("index-stale-labels.json")).read_text()
            )
            refused = run(
                "--graph-root",
                graph_root("stale-labels"),
                "--index-ref",
                "docker://example.invalid/ps-printer-app:test",
                env={"SKOPEO": mismatched},
            )
            self.assertEqual(refused.returncode, 1)
            self.assertIn("io.projectbluefin.fsdk.version", refused.stderr)

    def test_a_registry_tool_that_is_absent_is_fatal(self):
        result = run(
            "--graph-root",
            graph_root("consistent"),
            "--index-ref",
            "docker://example.invalid/ps-printer-app:test",
            env={"SKOPEO": str(Path(tempfile.gettempdir()) / "definitely-not-skopeo")},
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not installed", result.stderr)


class PromotionGateTest(unittest.TestCase):
    """Promotion must not be able to advance stable without the comparison."""

    def setUp(self):
        self.assertTrue(WORKFLOW.is_file(), f"{WORKFLOW} is missing")
        self.text = WORKFLOW.read_text()

    def job_block(self, job):
        lines = self.text.splitlines()
        start = next(i for i, line in enumerate(lines) if line == f"  {job}:")
        block = [lines[start]]
        for line in lines[start + 1:]:
            if line and not line.startswith(" ") and not line.startswith("\t"):
                break
            if re.match(r"^  \S", line):
                break
            block.append(line)
        return "\n".join(block)

    def test_the_stable_write_needs_the_metadata_comparison(self):
        promote = self.job_block("promote")
        self.assertIn("needs: [metadata, verify]", promote)

    def test_the_check_lives_outside_the_write_job(self):
        # The job that pushes stable must not be the job that decides whether it
        # may; a skip or a failure in that same job would still reach the push.
        self.assertIn("verify-fsdk-metadata.py", self.job_block("metadata"))
        self.assertNotIn("verify-fsdk-metadata.py", self.job_block("promote"))

    def test_stable_is_written_exactly_once(self):
        self.assertEqual(self.text.count("refs/heads/stable"), 1)
        self.assertIn("refs/heads/stable", self.job_block("promote"))

    def test_no_job_holds_write_permission_while_reading_metadata(self):
        metadata = self.job_block("metadata")
        self.assertIn("contents: read", metadata)
        self.assertNotIn("contents: write", metadata)

    def test_the_workflow_never_runs_on_a_pull_request(self):
        self.assertNotIn("pull_request_target", self.text)
        self.assertNotIn("\n  pull_request:", self.text)


if __name__ == "__main__":
    unittest.main()
