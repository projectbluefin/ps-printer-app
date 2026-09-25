"""Exercise the real metadata checker against fixtures that disagree.

These run ``scripts/verify-fsdk-metadata.py`` as a separate process, the way
CI runs it, over committed fixture trees and a vendored copy of fsdk-containers'
``elements/freedesktop-sdk.bst``. They are metadata tests: they say nothing about
OCI printing or physical paper output.

The case that matters is ``stale-labels``: the fsdk-containers junction moved
(update-base.yml does that daily), FSDK moved with it, and the OCI FSDK labels
still name the previous release. That tree must be refused with a diagnostic
naming both values, so a promotion stops before it writes ``stable``.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/verify-fsdk-metadata.py"
FIXTURES = REPO / "tests/fixtures/fsdk-metadata"
FSDK_JUNCTION = FIXTURES / "fsdk-containers/freedesktop-sdk.bst"

CONTAINERS_REF = "8a02f5e18b6d89c5558d2371212a5489e86c3ea2"
FSDK_VERSION = "26.08.1"
FSDK_REF = "b02b59ffe19a49a402f357fd5fcb1d552ebc50d7"
OLD_VERSION = "26.08.0"
OLD_REF = "db97cce32cecadc7a3e98f06d557ebfa6ba9ad46"


def run(*args, env=None):
    environment = {**os.environ, **(env or {})}
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        env=environment,
        text=True,
        capture_output=True,
    )


def offline(tree, *args, junction=FSDK_JUNCTION, env=None):
    """Check a fixture tree against a local fsdk-containers junction copy."""
    return run(
        "--graph-root", str(FIXTURES / tree), "--fsdk-junction", str(junction), *args, env=env
    )


# The fake upstream must not depend on the user's git configuration (signing, hooks).
GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "fixture",
    "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
    "GIT_COMMITTER_NAME": "fixture",
    "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
}


def git(*args, cwd):
    return subprocess.run(
        ["git", *args], cwd=cwd, env=GIT_ENV, check=True, capture_output=True, text=True
    ).stdout.strip()


class GraphTest(unittest.TestCase):
    """The nested FSDK pin against the labels the OCI element writes."""

    def test_a_consistent_graph_passes(self):
        result = offline("consistent")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(CONTAINERS_REF, result.stdout)
        self.assertIn("'%s' '%s'" % (FSDK_VERSION, FSDK_REF), result.stdout)
        self.assertEqual(result.stderr, "")

    def test_stale_labels_fail_naming_both_values(self):
        result = offline("stale-labels")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("FAIL: FSDK metadata mismatch", result.stderr)
        self.assertIn(
            "io.projectbluefin.fsdk.version is '%s' in elements/oci/ps-printer-app.bst "
            "but the graph pins '%s'" % (OLD_VERSION, FSDK_VERSION),
            result.stderr,
        )
        self.assertIn(
            "io.projectbluefin.fsdk.ref is '%s' in elements/oci/ps-printer-app.bst "
            "but the graph pins '%s'" % (OLD_REF, FSDK_REF),
            result.stderr,
        )

    def test_a_ref_mismatch_is_caught_when_the_version_agrees(self):
        result = offline("mismatched-ref")
        self.assertEqual(result.returncode, 1)
        self.assertIn("io.projectbluefin.fsdk.ref is '%s'" % OLD_REF, result.stderr)
        self.assertNotIn("io.projectbluefin.fsdk.version is", result.stderr)

    def test_an_unpinned_fsdk_containers_junction_fails_closed(self):
        result = offline("unpinned")
        self.assertEqual(result.returncode, 1)
        self.assertIn("carries no 'ref:' line", result.stderr)

    def test_a_missing_junction_fails_closed(self):
        result = offline("missing-junction")
        self.assertEqual(result.returncode, 1)
        self.assertIn("elements/fsdk-containers.bst does not exist", result.stderr)

    def test_a_missing_oci_element_fails_closed(self):
        result = offline("missing-oci")
        self.assertEqual(result.returncode, 1)
        self.assertIn("elements/oci/ps-printer-app.bst does not exist", result.stderr)

    def test_a_missing_fsdk_junction_copy_fails_closed(self):
        result = offline("consistent", junction=FIXTURES / "no-such-file.bst")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no-such-file.bst does not exist", result.stderr)

    def edited_tree(self, temp, junction=None, oci=None):
        root = Path(temp) / "tree"
        for name, text in (("fsdk-containers.bst", junction), ("oci/ps-printer-app.bst", oci)):
            source = FIXTURES / "consistent/elements" / name
            target = root / "elements" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text(source.read_text()) if text else source.read_text())
        return root

    def test_a_non_commit_fsdk_containers_ref_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = self.edited_tree(temp, junction=lambda t: t.replace(CONTAINERS_REF, "main"))
            result = run("--graph-root", str(root), "--fsdk-junction", str(FSDK_JUNCTION))
        self.assertEqual(result.returncode, 1)
        self.assertIn("pins fsdk-containers to 'main', which is not a 40-hex commit", result.stderr)

    def test_a_label_the_element_omits_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = self.edited_tree(
                temp, oci=lambda t: "".join(l for l in t.splitlines(True) if "fsdk.ref" not in l)
            )
            result = run("--graph-root", str(root), "--fsdk-junction", str(FSDK_JUNCTION))
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not set the io.projectbluefin.fsdk.ref label", result.stderr)

    def fsdk_junction(self, temp, text):
        path = Path(temp) / "freedesktop-sdk.bst"
        path.write_text(text(FSDK_JUNCTION.read_text()))
        return path

    def test_an_fsdk_ref_past_its_release_tag_fails_closed(self):
        # The version label names a point release; a commit after the tag is not it.
        with tempfile.TemporaryDirectory() as temp:
            junction = self.fsdk_junction(
                temp, lambda t: t.replace("26.08.1-0-g" + FSDK_REF, "26.08.1-3-g" + OLD_REF)
            )
            result = offline("consistent", junction=junction)
        self.assertEqual(result.returncode, 1)
        self.assertIn("3 commits past freedesktop-sdk-26.08.1", result.stderr)

    def test_an_unpinned_fsdk_junction_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            junction = self.fsdk_junction(
                temp, lambda t: t.replace("-0-g" + FSDK_REF, "")
            )
            result = offline("consistent", junction=junction)
        self.assertEqual(result.returncode, 1)
        self.assertIn("carries no 'ref: freedesktop-sdk-<version>-<n>-g<sha>' line", result.stderr)
        self.assertIn("'ref: freedesktop-sdk-26.08.1'", result.stderr)


class FetchTest(unittest.TestCase):
    """Without --fsdk-junction the pinned fsdk-containers commit is fetched."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        upstream = Path(self.temp.name) / "fsdk-containers"
        (upstream / "elements").mkdir(parents=True)
        git("init", "-q", cwd=upstream)
        git("config", "uploadpack.allowAnySHA1InWant", "true", cwd=upstream)
        (upstream / "elements/freedesktop-sdk.bst").write_text(FSDK_JUNCTION.read_text())
        git("add", ".", cwd=upstream)
        git("commit", "-qm", "pin", cwd=upstream)
        self.pinned = git("rev-parse", "HEAD", cwd=upstream)
        # A later commit moves FSDK, so fetching the wrong commit would be visible.
        (upstream / "elements/freedesktop-sdk.bst").write_text(
            FSDK_JUNCTION.read_text().replace(
                "26.08.1-0-g" + FSDK_REF, "26.08.0-0-g" + OLD_REF
            )
        )
        git("commit", "-qam", "move", cwd=upstream)
        self.url = upstream.as_uri()

    def tree(self, commit):
        root = Path(self.temp.name) / "tree"
        (root / "elements/oci").mkdir(parents=True, exist_ok=True)
        (root / "elements/fsdk-containers.bst").write_text(
            (FIXTURES / "consistent/elements/fsdk-containers.bst")
            .read_text()
            .replace(CONTAINERS_REF, commit)
        )
        (root / "elements/oci/ps-printer-app.bst").write_text(
            (FIXTURES / "consistent/elements/oci/ps-printer-app.bst").read_text()
        )
        return str(root)

    def test_the_pinned_commit_is_what_gets_compared(self):
        result = run("--graph-root", self.tree(self.pinned), "--fsdk-containers-url", self.url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.pinned, result.stdout)

    def test_a_commit_the_remote_does_not_have_fails_closed(self):
        missing = "0" * 40
        result = run("--graph-root", self.tree(missing), "--fsdk-containers-url", self.url)
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot read elements/freedesktop-sdk.bst of fsdk-containers %s" % missing, result.stderr)
        self.assertIn("git fetch exited", result.stderr)

    def test_an_unreachable_remote_fails_closed(self):
        result = run(
            "--graph-root",
            self.tree(self.pinned),
            "--fsdk-containers-url",
            (Path(self.temp.name) / "absent").as_uri(),
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("git fetch exited", result.stderr)


class ImageTest(unittest.TestCase):
    """--image compares the labels a built image actually carries."""

    def podman(self, temp, labels, exit_code=0):
        # Stands in for `podman image inspect --format '{{json .Labels}}' IMAGE`.
        stub = Path(temp) / "podman"
        body = labels if isinstance(labels, str) else json.dumps(labels)
        stub.write_text("#!/bin/sh\ncat <<'EOF'\n%s\nEOF\nexit %d\n" % (body, exit_code))
        stub.chmod(0o755)
        return {"PODMAN": str(stub)}

    def built(self, version=FSDK_VERSION, ref=FSDK_REF):
        return {
            "org.opencontainers.image.version": "20240504-20",
            "io.projectbluefin.fsdk.version": version,
            "io.projectbluefin.fsdk.ref": ref,
        }

    def test_a_matching_image_passes(self):
        with tempfile.TemporaryDirectory() as temp:
            result = offline("consistent", "--image", "ps:build", env=self.podman(temp, self.built()))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("and image ps:build", result.stdout)

    def test_an_image_built_from_stale_labels_fails_naming_both_values(self):
        with tempfile.TemporaryDirectory() as temp:
            env = self.podman(temp, self.built(OLD_VERSION, OLD_REF))
            result = offline("consistent", "--image", "ps:build", env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "io.projectbluefin.fsdk.version is '%s' in image ps:build but the graph pins '%s'"
            % (OLD_VERSION, FSDK_VERSION),
            result.stderr,
        )
        self.assertIn(
            "io.projectbluefin.fsdk.ref is '%s' in image ps:build but the graph pins '%s'"
            % (OLD_REF, FSDK_REF),
            result.stderr,
        )

    def test_an_image_without_an_fsdk_label_fails_closed(self):
        labels = self.built()
        del labels["io.projectbluefin.fsdk.ref"]
        with tempfile.TemporaryDirectory() as temp:
            result = offline("consistent", "--image", "ps:build", env=self.podman(temp, labels))
        self.assertEqual(result.returncode, 1)
        self.assertIn("io.projectbluefin.fsdk.ref is absent from image ps:build", result.stderr)

    def test_an_image_without_labels_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            result = offline("consistent", "--image", "ps:build", env=self.podman(temp, "null"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("image ps:build carries no labels", result.stderr)

    def test_a_failed_inspect_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            env = self.podman(temp, "Error: ps:build: image not known", exit_code=125)
            result = offline("consistent", "--image", "ps:build", env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot inspect ps:build (exit 125): Error: ps:build: image not known", result.stderr)

    def test_an_absent_podman_fails_closed(self):
        env = {"PODMAN": str(Path(tempfile.gettempdir()) / "definitely-not-podman")}
        result = offline("consistent", "--image", "ps:build", env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not installed", result.stderr)


if __name__ == "__main__":
    unittest.main()
