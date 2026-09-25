# Native FSDK image validation

`.github/workflows/fsdk-ci.yml` runs on every pull request to `testing`, in the
merge queue, and on manual dispatch. Pull requests only validate the BuildStream
graph (`just validate`); no image is built. The merge queue and
`workflow_dispatch` run the full native x86_64 and AArch64 build and verification,
each with a six-hour limit. A new commit to a pull request cancels that pull
request's previous run; merge-queue and dispatch runs are not cancelled.

Full builds restore BuildStream's local cache (`~/.cache/buildstream/cas`,
`artifacts`, `source_protos`) from the Actions cache, one entry per arch.
`ci/buildstream.conf` sets no cache quota, because BuildStream fails builds at
quota. Only `.github/workflows/bst-cache.yml` saves the cache (saved only when an
arch fits in 9000 MB uncompressed; a larger cache fails the refill): on pushes to
`testing` that touch graph inputs, nightly, and on dispatch.
Reset it with `gh cache delete --all -R projectbluefin/ps-printer-app`.

Both jobs inherit only `contents: read`. Checkout does not persist credentials,
and the workflow has no registry login, secrets, publishing step, or privileged
`pull_request_target` trigger. Public builder images and sources must be readable
without registry credentials. Legacy Snap/Rock packaging and registry workflows
remain separate; FSDK validation does not trigger a release workflow.

## The shared printing base

The graph builds on fsdk-containers' shared printing base, junctioned at a pinned
commit in `elements/fsdk-containers.bst`. `fsdk-containers.bst:printing/base.bst`
is the one provider of CUPS, cups-filters, libcupsfilters, libppd, ghostscript,
mutool, avahi-printing, PAPPL and pappl-retrofit, including their printer-app
patches; this repository adds no FSDK junction or patches of its own and reaches
FSDK only through `fsdk-containers.bst:freedesktop-sdk.bst:...`. The contract is
fsdk-containers' `docs/skills/printing-base.md`.

- The base is a devel stack. `printer-app/core-runtime.bst` composes the image
  from runtime domains only, and `just verify-no-devel` fails on headers, static
  or libtool archives, and pkg-config or CMake directories in the image.
- Before the full build, both workflows run `Seed printing base`: when the base
  is not already cached it pulls
  `ghcr.io/projectbluefin/printing-base-devel:<arch>-<full-key>`, verifies its
  keyless cosign signature, and only then extracts it into the local cache.
  The step never fails the job; any error is a `::warning::` and the base is
  built locally.
- `.github/workflows/update-base.yml` tracks fsdk-containers `main` daily and
  proposes a `deps/fsdk-containers` pull request against `testing`.

## Build interface

The prerequisite job checks the interface files below and reports a skip only
when the whole graph is absent; a partial graph fails it.

The workflow follows the Ghostscript appliance's build interface:

- `project.conf` and `elements/oci/ps-printer-app.bst` define the image graph.
- `Justfile` (or `justfile`) provides `bst`, `validate`, `build`, and `verify`
  recipes; `build` and `verify` must not depend on a `fetch` recipe.
- `just validate` runs `bst show --deps all oci/ps-printer-app.bst` (pull requests).
- `just bst --config /src/ci/buildstream.conf --network-retries 5 build
  oci/ps-printer-app.bst` builds the image, fetching only uncached sources. CI
  never runs `bst source fetch --deps all`.
- `just build` exports the complete local OCI image.
- `just verify` runs full appliance and payload verification, including executable
  `tests/core-appliance.sh` and `tests/core-payload.sh`. The payload test must send
  a real IPP job through the driver/filter/socket backend, check format-specific
  output bytes, and require job completion. It must also cover the persistence
  and coexistence contracts from #4 and #5. Synthetic echoes are not sufficient.

A partial graph fails the prerequisite check instead of skipping native builds.
The prerequisite check only checks interface files; the recipes and tests must
implement the behavior above. Physical paper output remains unverified without
hardware.

Validate workflow edits with `actionlint .github/workflows/fsdk-ci.yml
.github/workflows/bst-cache.yml`. After prerequisites land, both native jobs must
pass before claiming #6 is complete.
