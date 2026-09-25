# FSDK metadata fixtures

Small, self-contained trees for `tests/test_fsdk_metadata.py`. Each one is a
slice of a real `elements/` directory: enough of `freedesktop-sdk.bst` and
`elements/oci/ps-printer-app.bst` for `scripts/verify-fsdk-metadata.py` to read
the FSDK pin and the FSDK labels.

They exist because the interesting cases cannot be checked against the live
tree. The mismatch this gate refuses is a commit that bumps one copy of the
FSDK pin and leaves the other behind, and a fixture is the only way to hold that
state still long enough to assert on it.

| Fixture | What it holds |
| --- | --- |
| `consistent/` | A junction and an OCI element that agree. |
| `stale-labels/` | **The intentionally mismatched fixture.** The junction moved to a newer FSDK point release; the labels still name the old version and the old commit. |
| `mismatched-ref/` | The junction was re-pinned to a different commit on the same release line; the labels still name the old commit. The version matches, so this is the case a version-only comparison would miss. |
| `unpinned/` | The junction tracks a branch without pinning a commit, so nothing can be compared. |
| `missing-junction/` | Only the OCI element exists — a partially landed graph. |
| `missing-oci/` | Only the junction exists. |

`index-*.json` are raw OCI index documents shaped like the ones
`skopeo inspect --raw` returns for the published multi-architecture index. They
are described relative to a graph, so the pairing is what matters:

| Index document | Describes | Pair it with |
| --- | --- | --- |
| `index-consistent.json` | the pin in `consistent/` | `consistent/` to pass |
| `index-stale-labels.json` | the pin *before* the bump | `stale-labels/` to fail |
| `index-missing-fsdk-ref.json` | the pin minus the ref annotation | `consistent/` to fail |
| `index-no-annotations.json` | an index with no annotations at all | `consistent/` to fail |
| `index-single-arch.json` | an amd64-only index | `consistent/` to fail under `--require-multiarch` |
| `index-manifest.json` | an image manifest, not an index | `consistent/` to fail |

None of these fixtures is evidence about printing. They exercise a metadata
comparison, not an image.
