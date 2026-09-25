#!/usr/bin/env python3
"""Reject FSDK metadata that does not describe the graph it was built from.

The appliance is built against a pinned freedesktop-sdk junction, and the OCI
artifact advertises that pin as labels on every architecture image and as
annotations on the multi-architecture index:

    io.projectbluefin.fsdk.version   the freedesktop-sdk point release
    io.projectbluefin.fsdk.ref       the freedesktop-sdk commit

Those two facts are written in three independent places — the junction source
in ``elements/freedesktop-sdk.bst``, the ``build-oci`` label block in
``elements/oci/ps-printer-app.bst``, and whatever the published index carries.
A commit can bump one without touching the others, and the drift is invisible
until something reads the metadata back. This checker reads all of them and
refuses to pass when they disagree.

With no arguments it compares the graph against itself, which is a source-only
check and needs no registry, no build and no credentials. Pass ``--index`` (a
file, or ``-`` for stdin) or ``--index-ref`` (anything ``skopeo inspect --raw``
accepts, e.g. ``docker://ghcr.io/projectbluefin/ps-printer-app:20240504-20``) to
also compare against real index metadata.

Every path fails closed. A missing file, an unpinned junction, an index without
annotations, an unreachable registry or a registry authentication failure all
exit non-zero with a diagnostic naming what could not be proven, because a
promotion gate that treats "could not read the metadata" as "metadata agrees"
is worse than no gate at all.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Sequence

# The FSDK facts, and where each of them is written down.
LABEL_VERSION = "io.projectbluefin.fsdk.version"
LABEL_REF = "io.projectbluefin.fsdk.ref"
LABEL_APP_VERSION = "org.opencontainers.image.version"

JUNCTION = "elements/freedesktop-sdk.bst"
OCI_ELEMENT = "elements/oci/ps-printer-app.bst"
VERSION_FILE = "VERSION"

# project.conf sets `ref-format: git-describe`, so the junction ref carries both
# facts: the point release and the commit, as `freedesktop-sdk-<version>-<n>-g<sha>`.
JUNCTION_REF = re.compile(
    r"^[ \t]*ref:[ \t]*freedesktop-sdk-(?P<version>\S+?)-(?P<count>[0-9]+)-g(?P<ref>[0-9a-f]{40})[ \t]*$",
    re.MULTILINE,
)

# How many architecture manifests a promotable index must carry.
REQUIRED_PLATFORMS = ("amd64", "arm64")


class Failure(Exception):
    """A condition that must stop the caller rather than be worked around."""


def quote(value: str) -> str:
    return "'%s'" % value


def label_pattern(label: str) -> re.Pattern[str]:
    key = re.escape(label)
    return re.compile(
        r"""^[ \t]*['"]""" + key + r"""['"][ \t]*:[ \t]*['"](?P<value>[^'"]*)['"][ \t]*$""",
        re.MULTILINE,
    )


def read_text(path: Path, describes: str) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise Failure(
            "%s does not exist, so %s cannot be compared" % (path, describes)
        ) from None
    except OSError as error:
        raise Failure("cannot read %s: %s" % (path, error)) from None


def read_pin(graph_root: Path) -> tuple[str, str]:
    """Return the (version, ref) the junction is pinned to."""
    path = graph_root / JUNCTION
    text = read_text(path, "the pinned FSDK junction")

    matches = list(JUNCTION_REF.finditer(text))
    if not matches:
        raise Failure(
            "%s carries no 'ref: freedesktop-sdk-<version>-<n>-g<sha>' line, so the "
            "FSDK pin cannot be read" % path
        )
    if len(matches) > 1:
        found = ", ".join(quote(match.group(0).strip()) for match in matches)
        raise Failure(
            "%s pins more than one freedesktop-sdk ref (%s); the FSDK pin is ambiguous"
            % (path, found)
        )

    return matches[0].group("version"), matches[0].group("ref")


def read_labels(graph_root: Path) -> dict[str, str]:
    """Return the FSDK labels the OCI element writes into the image."""
    path = graph_root / OCI_ELEMENT
    text = read_text(path, "the FSDK labels written into the image")

    labels = {}
    for label in (LABEL_VERSION, LABEL_REF):
        matches = list(label_pattern(label).finditer(text))
        if not matches:
            raise Failure(
                "%s does not set the %s label, so the image would ship without it"
                % (path, label)
            )
        if len(matches) > 1:
            raise Failure(
                "%s sets the %s label %d times; the value to compare is ambiguous"
                % (path, label, len(matches))
            )
        labels[label] = matches[0].group("value")

    return labels


def read_index_json(index: str) -> tuple[Any, str]:
    """Read index metadata from a file, stdin, or the registry."""
    if index == "-":
        raw = sys.stdin.read()
        origin = "standard input"
    elif index.startswith("docker://") or index.startswith("oci:"):
        raw = skopeo_inspect_raw(index)
        origin = index
    else:
        path = Path(index)
        try:
            raw = path.read_text(encoding="utf-8")
        except OSError as error:
            raise Failure(
                "cannot read index metadata from %s: %s" % (index, error)
            ) from None
        origin = str(path)

    try:
        return json.loads(raw), origin
    except json.JSONDecodeError as error:
        raise Failure(
            "index metadata from %s is not JSON: %s" % (origin, error)
        ) from None


def skopeo_inspect_raw(reference: str) -> str:
    """Return the raw index document for a registry reference.

    A failed lookup is fatal. ``skopeo inspect`` also exits non-zero when the
    registry is unreachable or the credentials are wrong, so a non-zero exit is
    never read as "the metadata is absent".
    """
    skopeo = os.environ.get("SKOPEO", "skopeo")
    try:
        result = subprocess.run(
            [skopeo, "inspect", "--raw", reference],
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        raise Failure(
            "cannot read index metadata for %s: %s is not installed" % (reference, skopeo)
        ) from None

    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip() or "no diagnostic"
        raise Failure(
            "cannot read index metadata for %s (exit %d): %s"
            % (reference, result.returncode, detail)
        )

    return result.stdout


def index_annotations(document: Any, origin: str) -> dict[str, str]:
    """Return the index annotations, refusing anything that is not an index.

    An OCI image manifest also has an ``annotations`` key, so the ``manifests``
    list is what separates the multi-architecture index from a single
    architecture image. Comparing against a manifest would silently skip the
    index entirely, which is where the FSDK labels are most easily dropped.
    """
    if not isinstance(document, dict):
        raise Failure("index metadata from %s is not a JSON object" % origin)

    manifests = document.get("manifests")
    if not isinstance(manifests, list) or not manifests:
        raise Failure(
            "index metadata from %s has no 'manifests' list, so it is an image "
            "manifest rather than the multi-architecture index" % origin
        )

    annotations = document.get("annotations")
    if not isinstance(annotations, dict):
        raise Failure(
            "index metadata from %s carries no 'annotations' object, so it declares "
            "no FSDK version or ref" % origin
        )

    return {str(key): str(value) for key, value in annotations.items()}


def index_platforms(document: dict[str, Any]) -> list[str]:
    platforms = []
    for manifest in document.get("manifests", []):
        if not isinstance(manifest, dict):
            continue
        platform = manifest.get("platform")
        if isinstance(platform, dict) and platform.get("architecture"):
            platforms.append(str(platform["architecture"]))
    return platforms


def compare(
    expected: str,
    label: str,
    actual: str | None,
    where: str,
    mismatches: list[str],
) -> None:
    if actual is None:
        mismatches.append(
            "%s is absent from %s; the graph pins %s" % (label, where, quote(expected))
        )
    elif actual != expected:
        mismatches.append(
            "%s is %s in %s but the graph pins %s"
            % (label, quote(actual), where, quote(expected))
        )


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare the pinned FSDK junction with the metadata that ships with the image.",
    )
    parser.add_argument(
        "--graph-root",
        default=None,
        help="tree holding elements/ and VERSION (default: the repository root)",
    )
    parser.add_argument(
        "--index",
        default=None,
        help="index metadata as a JSON file, or - for standard input",
    )
    parser.add_argument(
        "--index-ref",
        default=None,
        help="registry reference whose raw index metadata is read with skopeo",
    )
    parser.add_argument(
        "--app-version",
        default=None,
        help="application version the index metadata must also declare",
    )
    parser.add_argument(
        "--require-multiarch",
        action="store_true",
        help="require the index to carry every architecture in %s"
        % (", ".join(REQUIRED_PLATFORMS),),
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    graph_root = (
        Path(args.graph_root)
        if args.graph_root
        else Path(__file__).resolve().parent.parent
    )

    try:
        version, ref = read_pin(graph_root)
        labels = read_labels(graph_root)

        compared: list[str] = []
        mismatches: list[str] = []

        # The graph against itself: the junction pin and the labels the image is
        # built with are two separate copies of the same fact.
        compare(version, LABEL_VERSION, labels[LABEL_VERSION], OCI_ELEMENT, mismatches)
        compare(ref, LABEL_REF, labels[LABEL_REF], OCI_ELEMENT, mismatches)
        compared.append("%s in %s" % ("the FSDK labels", OCI_ELEMENT))

        if args.index and args.index_ref:
            raise Failure("--index and --index-ref are mutually exclusive")

        index_sources = [source for source in (args.index, args.index_ref) if source]
        for source in index_sources:
            document, origin = read_index_json(source)
            annotations = index_annotations(document, origin)

            compare(version, LABEL_VERSION, annotations.get(LABEL_VERSION), origin, mismatches)
            compare(ref, LABEL_REF, annotations.get(LABEL_REF), origin, mismatches)
            compared.append("the index annotations of %s" % origin)

            if args.app_version:
                compare(
                    args.app_version,
                    LABEL_APP_VERSION,
                    annotations.get(LABEL_APP_VERSION),
                    origin,
                    mismatches,
                )

            if args.require_multiarch:
                platforms = index_platforms(document)
                missing = [arch for arch in REQUIRED_PLATFORMS if arch not in platforms]
                if missing:
                    mismatches.append(
                        "the index at %s carries platforms [%s] and is missing %s"
                        % (origin, ", ".join(platforms) or "none", ", ".join(missing))
                    )

        if mismatches:
            print("FAIL: FSDK metadata mismatch", file=sys.stderr)
            print(
                "  the graph pins FSDK %s %s" % (quote(version), quote(ref)),
                file=sys.stderr,
            )
            for mismatch in mismatches:
                print("  %s" % mismatch, file=sys.stderr)
            return 1

        print(
            "OK: FSDK %s %s matches %s"
            % (quote(version), quote(ref), " and ".join(compared))
        )
        return 0
    except Failure as failure:
        print("FAIL: %s" % failure, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
