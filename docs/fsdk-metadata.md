# The FSDK metadata gate

FSDK is reached only through the fsdk-containers junction, so its pin is nested:

1. `elements/fsdk-containers.bst` pins fsdk-containers to a commit (`ref:`, a
   plain 40-hex commit; `update-base.yml` moves it).
2. fsdk-containers' `elements/freedesktop-sdk.bst` at that commit pins FSDK as
   `ref: freedesktop-sdk-<version>-0-g<commit>` (fsdk-containers uses
   `ref-format: git-describe`).

The image states that pin in two labels, written by hand into the `build-oci`
block of `elements/oci/ps-printer-app.bst`:

| Label | Meaning |
| --- | --- |
| `io.projectbluefin.fsdk.version` | the freedesktop-sdk point release |
| `io.projectbluefin.fsdk.ref` | the freedesktop-sdk commit |

Moving the fsdk-containers junction can move FSDK without touching those labels.
The image still builds, prints and passes `just verify`; only a reader of the
metadata notices. `scripts/verify-fsdk-metadata.py` resolves the nested pin and
refuses labels that disagree with it.

## Running it

```sh
# The nested pin against the OCI element labels. Fetches the pinned
# fsdk-containers commit from GitHub; no build, no credentials.
python3 scripts/verify-fsdk-metadata.py

# Also against the labels of a built image (podman image inspect).
python3 scripts/verify-fsdk-metadata.py --image ghcr.io/projectbluefin/ps-printer-app:build

# Offline: supply fsdk-containers' elements/freedesktop-sdk.bst at the pinned
# commit yourself. You vouch that the file is that commit's copy.
python3 scripts/verify-fsdk-metadata.py --fsdk-junction path/to/freedesktop-sdk.bst
```

`--fsdk-containers-url` fetches from another fsdk-containers repository;
`--image` may be repeated. `GIT` and `PODMAN` override the tools used.

## Where it runs

- `.github/workflows/fsdk-metadata.yml` runs the unit tests and the comparison
  against the OCI element on every pull request and push to `testing`, so an
  fsdk-containers bump that moves FSDK fails on its own pull request. It builds
  nothing and holds no credentials.
- `.github/workflows/promote-stable.yml` runs the comparison in its `metadata`
  job before any build, and again in each native `verify` job against the labels
  of the image `just build` produced, before `just verify`. The `promote` job,
  the only one with `contents: write`, needs both. A mismatch leaves `stable`
  untouched.
- `.github/workflows/registry-actions.yml` repeats the element comparison when
  a `v*` tag is released and stamps the same values onto the published images.

Promotion compares the image it builds and verifies, not a published index:
images are published only from `v*` tags on `stable`, after promotion, so no
index exists for a candidate yet.

## What it refuses

Every case exits non-zero with a diagnostic:

- the labels in the OCI element, or of a built image, disagree with the pin (the
  diagnostic names the label, both values and where the wrong one came from);
- `elements/fsdk-containers.bst` or the OCI element is missing, the junction has
  no `ref:`, more than one, or one that is not a 40-hex commit;
- fsdk-containers' `elements/freedesktop-sdk.bst` cannot be fetched or read, has
  no `ref: freedesktop-sdk-<version>-<n>-g<commit>` line or more than one, or
  pins a commit past its release tag (`<n>` is not 0), which no point release
  describes;
- the OCI element or the image omits a label, the element sets one twice, or
  `podman image inspect` fails.

## What it does not claim

This is a metadata comparison. It says nothing about whether the image runs,
what it prints, or whether the pinned FSDK is a good one; that is `just verify`.
Physical paper output remains unverified without printer hardware.
