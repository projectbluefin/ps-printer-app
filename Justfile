# BuildStream runs in the same pinned freedesktop-sdk builder image as the
# Ghostscript appliance, so both appliances build with one reviewed toolchain.
bst2_image := env("BST2_IMAGE", "registry.gitlab.com/freedesktop-sdk/infrastructure/freedesktop-sdk-docker-images/bst2:64eb0b4930d57a92710822898fb73af6cc1ae35d")
image_ref := env("IMAGE_REF", "ghcr.io/projectbluefin/ps-printer-app:build")

default:
    @just --list

bst *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "${HOME}/.cache/buildstream"
    podman run --rm \
        --privileged \
        --device /dev/fuse \
        --network=host \
        -v "{{ justfile_directory() }}:/src:rw" \
        -v "${HOME}/.cache/buildstream:/root/.cache/buildstream:rw" \
        -w /src \
        "{{ bst2_image }}" \
        bash -c 'bst "$@"' -- --no-interactive {{ ARGS }}

# Resolve the complete graph without building it.
validate:
    just bst show --deps all elements/oci/ps-printer-app.bst

fetch:
    #!/usr/bin/env bash
    set -euo pipefail
    for attempt in 1 2 3; do
        if just bst source fetch --deps all elements/oci/ps-printer-app.bst; then
            exit 0
        fi
        echo "source fetch failed (attempt ${attempt}/3)" >&2
        if [[ "$attempt" -lt 3 ]]; then sleep 15; fi
    done
    exit 1

build:
    #!/usr/bin/env bash
    set -euo pipefail
    just bst build elements/oci/ps-printer-app.bst
    just export

export:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf .build-out
    just bst artifact checkout elements/oci/ps-printer-app.bst --directory /src/.build-out
    IMAGE_ID=$(podman pull -q oci:.build-out)
    rm -rf .build-out
    podman tag "$IMAGE_ID" "{{ image_ref }}"

# Graph shape: one CUPS artifact owner, immutable sources, no runtime toolchain.
# Pass --sources to also check out the pinned sources and prove the shared CUPS
# patches still apply to the pinned freedesktop-sdk line.
# Resolve, inspect and source-verify the printing graph.
verify-graph *ARGS:
    tests/printing-graph.sh {{ ARGS }}

# The shared CUPS patch seam still resolves against the pinned freedesktop-sdk.
verify-cups-patch-chain:
    tests/cups-patch-chain.sh

# A staged runtime closure that carries no compiler or package manager.
verify-runtime-closure:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf .build-runtime
    trap 'rm -rf .build-runtime' EXIT
    just bst artifact checkout elements/printer-app/core-runtime.bst --directory /src/.build-runtime
    tests/runtime-closure.sh .build-runtime

# Full verification of a built image. The appliance and payload suites are owned
# by the runtime and payload issues; this recipe requires them and never treats
# their absence as a pass.
# Verify a built image: graph, CUPS seam, closure, then appliance and payload.
verify:
    #!/usr/bin/env bash
    set -euo pipefail
    just validate
    just verify-graph --sources
    just verify-cups-patch-chain
    just verify-runtime-closure
    for suite in tests/core-appliance.sh tests/core-payload.sh; do
        if [[ ! -x "$suite" ]]; then
            printf 'FAIL: %s is required for full image verification and is not executable\n' "$suite" >&2
            printf 'Graph checks passed, but this is not image validation evidence.\n' >&2
            exit 1
        fi
        "$suite"
    done
