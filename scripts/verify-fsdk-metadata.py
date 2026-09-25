#!/usr/bin/env python3
"""Reject FSDK metadata that does not describe the graph it was built from.

FSDK is reached only through the fsdk-containers junction. The pin is nested:

    elements/fsdk-containers.bst             pins fsdk-containers by commit
    fsdk-containers elements/freedesktop-sdk.bst at that commit
                                             pins FSDK as
                                             freedesktop-sdk-<version>-0-g<ref>

The image advertises that pin as two labels, written by hand into the
``build-oci`` block of ``elements/oci/ps-printer-app.bst``:

    io.projectbluefin.fsdk.version   the freedesktop-sdk point release
    io.projectbluefin.fsdk.ref       the freedesktop-sdk commit

Moving the fsdk-containers junction (update-base.yml does it daily) can move
FSDK without anyone touching those labels. This checker resolves the nested pin
and refuses to pass when the labels disagree with it. With ``--image`` it also
reads the labels of a built image with ``podman image inspect`` and compares
those, so a promotion can check the image it actually built and verified.

fsdk-containers' ``elements/freedesktop-sdk.bst`` is fetched from
``--fsdk-containers-url`` at the pinned commit. ``--fsdk-junction FILE`` reads it
from a local file instead (tests, offline use); the caller then vouches that the
file is that commit's copy.

Every path fails closed: a missing file, an unpinned or ambiguous junction, an
FSDK ref that is not exactly a release tag, a failed fetch, a failed
``podman image inspect`` or an image without the labels all exit non-zero,
because "could not read the metadata" is never "the metadata agrees".
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Sequence

LABEL_VERSION = "io.projectbluefin.fsdk.version"
LABEL_REF = "io.projectbluefin.fsdk.ref"
LABELS = (LABEL_VERSION, LABEL_REF)

JUNCTION = "elements/fsdk-containers.bst"
OCI_ELEMENT = "elements/oci/ps-printer-app.bst"
FSDK_JUNCTION = "elements/freedesktop-sdk.bst"
FSDK_CONTAINERS_URL = "https://github.com/projectbluefin/fsdk-containers.git"

# elements/fsdk-containers.bst keeps a plain commit (update-base.yml restores it
# after tracking), and that is what the release job reads too.
CONTAINERS_REF = re.compile(r"^[ \t]*ref:[ \t]*(?P<value>\S+)[ \t]*$", re.MULTILINE)
COMMIT = re.compile(r"^[0-9a-f]{40}$")

# fsdk-containers sets `ref-format: git-describe`, so the FSDK junction ref
# carries the point release, the distance from its tag, and the commit.
FSDK_REF = re.compile(
    r"^[ \t]*ref:[ \t]*freedesktop-sdk-(?P<version>\S+?)-(?P<count>[0-9]+)-g(?P<ref>[0-9a-f]{40})[ \t]*$",
    re.MULTILINE,
)
ANY_REF = re.compile(r"^[ \t]*ref:.*$", re.MULTILINE)


class Failure(Exception):
    """A condition that must stop the caller rather than be worked around."""


def read_text(path: Path, describes: str) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise Failure("%s does not exist, so %s cannot be read" % (path, describes)) from None
    except OSError as error:
        raise Failure("cannot read %s: %s" % (path, error)) from None


def read_containers_ref(graph_root: Path) -> str:
    """Return the fsdk-containers commit the junction pins."""
    path = graph_root / JUNCTION
    text = read_text(path, "the fsdk-containers pin")
    refs = [match.group("value") for match in CONTAINERS_REF.finditer(text)]
    if not refs:
        raise Failure("%s carries no 'ref:' line, so fsdk-containers is not pinned" % path)
    if len(refs) > 1:
        raise Failure(
            "%s pins more than one ref (%s); the fsdk-containers pin is ambiguous"
            % (path, ", ".join("'%s'" % ref for ref in refs))
        )
    if not COMMIT.match(refs[0]):
        raise Failure(
            "%s pins fsdk-containers to '%s', which is not a 40-hex commit" % (path, refs[0])
        )
    return refs[0]


def fetch_fsdk_junction(url: str, commit: str) -> str:
    """Return fsdk-containers' elements/freedesktop-sdk.bst at ``commit``."""
    git = os.environ.get("GIT", "git")
    with tempfile.TemporaryDirectory() as scratch:
        steps = (
            ("init", [git, "init", "-q", scratch]),
            ("fetch", [git, "-C", scratch, "fetch", "-q", "--depth=1", url, commit]),
            ("show", [git, "-C", scratch, "show", "FETCH_HEAD:" + FSDK_JUNCTION]),
        )
        for name, step in steps:
            try:
                result = subprocess.run(step, check=False, capture_output=True, text=True)
            except FileNotFoundError:
                raise Failure("cannot fetch %s: %s is not installed" % (url, git)) from None
            if result.returncode != 0:
                detail = (result.stderr or result.stdout).strip() or "no diagnostic"
                raise Failure(
                    "cannot read %s of fsdk-containers %s from %s (git %s exited %d): %s"
                    % (FSDK_JUNCTION, commit, url, name, result.returncode, detail)
                )
    return result.stdout


def read_fsdk_pin(text: str, origin: str) -> tuple[str, str]:
    """Return the (version, ref) the FSDK junction pins."""
    matches = list(FSDK_REF.finditer(text))
    if not matches:
        found = [match.group(0).strip() for match in ANY_REF.finditer(text)]
        raise Failure(
            "%s carries no 'ref: freedesktop-sdk-<version>-<n>-g<sha>' line (found %s), "
            "so the FSDK pin cannot be read"
            % (origin, ", ".join("'%s'" % line for line in found) or "no ref")
        )
    if len(matches) > 1:
        raise Failure(
            "%s pins more than one freedesktop-sdk ref (%s); the FSDK pin is ambiguous"
            % (origin, ", ".join("'%s'" % match.group(0).strip() for match in matches))
        )
    match = matches[0]
    if match.group("count") != "0":
        raise Failure(
            "%s pins FSDK %s commits past freedesktop-sdk-%s (%s), so no point release "
            "describes it" % (origin, match.group("count"), match.group("version"), match.group("ref"))
        )
    return match.group("version"), match.group("ref")


def label_pattern(label: str) -> re.Pattern[str]:
    return re.compile(
        r"""^[ \t]*['"]""" + re.escape(label) + r"""['"][ \t]*:[ \t]*['"](?P<value>[^'"]*)['"][ \t]*$""",
        re.MULTILINE,
    )


def read_element_labels(graph_root: Path) -> dict[str, str]:
    """Return the FSDK labels the OCI element writes into the image."""
    path = graph_root / OCI_ELEMENT
    text = read_text(path, "the FSDK labels written into the image")
    labels = {}
    for label in LABELS:
        matches = list(label_pattern(label).finditer(text))
        if not matches:
            raise Failure("%s does not set the %s label" % (path, label))
        if len(matches) > 1:
            raise Failure(
                "%s sets the %s label %d times; the value to compare is ambiguous"
                % (path, label, len(matches))
            )
        labels[label] = matches[0].group("value")
    return labels


def read_image_labels(image: str) -> dict[str, str]:
    """Return the labels of a built image, via ``podman image inspect``."""
    podman = os.environ.get("PODMAN", "podman")
    try:
        result = subprocess.run(
            [podman, "image", "inspect", "--format", "{{json .Labels}}", image],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        raise Failure("cannot inspect %s: %s is not installed" % (image, podman)) from None
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip() or "no diagnostic"
        raise Failure("cannot inspect %s (exit %d): %s" % (image, result.returncode, detail))
    try:
        labels = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise Failure("labels of %s are not JSON: %s" % (image, error)) from None
    if not isinstance(labels, dict):
        raise Failure("image %s carries no labels" % image)
    return {str(key): str(value) for key, value in labels.items()}


def compare(pin: dict[str, str], labels: dict[str, str], where: str, mismatches: list[str]) -> None:
    for label in LABELS:
        actual = labels.get(label)
        if actual is None:
            mismatches.append("%s is absent from %s; the graph pins '%s'" % (label, where, pin[label]))
        elif actual != pin[label]:
            mismatches.append(
                "%s is '%s' in %s but the graph pins '%s'" % (label, actual, where, pin[label])
            )


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare the nested FSDK pin with the FSDK labels of the OCI element and, "
        "optionally, a built image.",
    )
    parser.add_argument(
        "--graph-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="tree holding elements/ (default: the repository root)",
    )
    parser.add_argument(
        "--fsdk-containers-url",
        default=FSDK_CONTAINERS_URL,
        help="fsdk-containers repository to fetch the pinned commit from (default: %(default)s)",
    )
    parser.add_argument(
        "--fsdk-junction",
        type=Path,
        help="local copy of fsdk-containers' %s at the pinned commit; skips the fetch" % FSDK_JUNCTION,
    )
    parser.add_argument(
        "--image",
        action="append",
        default=[],
        help="built image whose labels must also match (podman image inspect); repeatable",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    try:
        commit = read_containers_ref(args.graph_root)
        if args.fsdk_junction:
            origin = str(args.fsdk_junction)
            text = read_text(args.fsdk_junction, "the FSDK pin of fsdk-containers %s" % commit)
        else:
            origin = "fsdk-containers %s:%s" % (commit, FSDK_JUNCTION)
            text = fetch_fsdk_junction(args.fsdk_containers_url, commit)
        version, ref = read_fsdk_pin(text, origin)
        pin = {LABEL_VERSION: version, LABEL_REF: ref}

        mismatches: list[str] = []
        compare(pin, read_element_labels(args.graph_root), OCI_ELEMENT, mismatches)
        compared = [OCI_ELEMENT]
        for image in args.image:
            compare(pin, read_image_labels(image), "image %s" % image, mismatches)
            compared.append("image %s" % image)
    except Failure as failure:
        print("FAIL: %s" % failure, file=sys.stderr)
        return 1

    if mismatches:
        print("FAIL: FSDK metadata mismatch", file=sys.stderr)
        print(
            "  %s (fsdk-containers %s) pins FSDK '%s' '%s'" % (JUNCTION, commit, version, ref),
            file=sys.stderr,
        )
        for mismatch in mismatches:
            print("  %s" % mismatch, file=sys.stderr)
        return 1

    print(
        "OK: fsdk-containers %s pins FSDK '%s' '%s', matching %s"
        % (commit, version, ref, " and ".join(compared))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
