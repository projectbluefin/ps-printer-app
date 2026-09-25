# FSDK metadata fixtures

Trees for `tests/test_fsdk_metadata.py`, each a slice of `elements/` with only
what `scripts/verify-fsdk-metadata.py` reads: `elements/fsdk-containers.bst`
(pinned to fsdk-containers `8a02f5e18b6d89c5558d2371212a5489e86c3ea2`) and the
label block of `elements/oci/ps-printer-app.bst`.

`fsdk-containers/freedesktop-sdk.bst` is fsdk-containers' own
`elements/freedesktop-sdk.bst` at that commit, verbatim. It pins FSDK
`26.08.1` (`b02b59ffe19a49a402f357fd5fcb1d552ebc50d7`) and is passed with
`--fsdk-junction` so the tests need no network.

| Tree | What it holds |
| --- | --- |
| `consistent/` | Labels naming FSDK 26.08.1, matching the pin. |
| `stale-labels/` | **The intentionally mismatched fixture.** The junction moved to fsdk-containers 8a02f5e (FSDK 26.08.1); the labels still name FSDK 26.08.0 (`db97cce3…`), as pinned by fsdk-containers ff2b211. |
| `mismatched-ref/` | Labels naming the right version with the wrong commit, which a version-only comparison would miss. |
| `unpinned/` | A junction that tracks `main` without a `ref:`. |
| `missing-junction/` | No `elements/fsdk-containers.bst`. |
| `missing-oci/` | No `elements/oci/ps-printer-app.bst`. |

None of these is evidence about printing.
