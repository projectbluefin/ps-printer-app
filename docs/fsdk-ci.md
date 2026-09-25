# Native FSDK image validation

`.github/workflows/fsdk-ci.yml` runs on every pull request to `testing`, in the
merge queue, and on manual dispatch. Pull requests only validate the BuildStream
graph (`just validate`); no image is built. The merge queue and
`workflow_dispatch` run the full native x86_64 and AArch64 build and verification,
each with a six-hour limit. A new commit to a pull request cancels that pull
request's previous run; merge-queue and dispatch runs are not cancelled.

Full builds restore BuildStream's local cache (`~/.cache/buildstream/cas`,
`artifacts`, `source_protos`) from the Actions cache, one entry per arch, capped
by `ci/buildstream.conf` at a 4G quota. Only `.github/workflows/bst-cache.yml`
saves it: on pushes to `testing` that touch graph inputs, nightly, and on dispatch.
Reset it with `gh cache delete --all -R projectbluefin/ps-printer-app`.

Both jobs inherit only `contents: read`. Checkout does not persist credentials,
and the workflow has no registry login, secrets, publishing step, or privileged
`pull_request_target` trigger. Public builder images and sources must be readable
without registry credentials. Legacy Snap/Rock packaging and registry workflows
remain separate; FSDK validation does not trigger a release workflow.

## Prerequisite integration

Issues #2-#5 have not yet supplied the FSDK graph, runtime, and real socket-sink
harness. Until that work lands, the prerequisite job explicitly reports a skip;
a green prerequisite job is **not** proof of a passing image build. Issue #6
must remain open until both native builds and real verification have passed.
Remove the bootstrap skip once the graph is integrated.

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
