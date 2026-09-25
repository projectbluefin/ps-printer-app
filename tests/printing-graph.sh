#!/usr/bin/env bash
# Run on each native architecture; graph mode also supports cross-architecture
# inspection. Pass --sources to also check out the pinned sources and prove the
# shared CUPS patches still apply to the chosen freedesktop-sdk line.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
arch="${ARCH:-$(uname -m)}"
bst="${BST:-just bst}"
target=printer-app/core-runtime.bst
cups=freedesktop-sdk.bst:components/_private/cups-base.bst
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# shellcheck disable=SC2086 # $bst is intentionally word-split to allow "just bst".
$bst --no-interactive -o arch "$arch" show --deps all --format '%{name}' "$target" > "$work/graph"
# shellcheck disable=SC2086
$bst --no-interactive -o arch "$arch" show --deps all --format '%{state}' "$target" > "$work/states"
if grep -q 'no reference' "$work/states"; then
    echo 'Unpinned source in printing graph' >&2
    exit 1
fi

# Exactly one CUPS source owner for the whole graph.
cups_count="$(grep -c ':components/_private/cups-base.bst$' "$work/graph" || true)"
if [[ "$cups_count" != 1 ]]; then
    printf 'FAIL: expected one CUPS base provider, found %s\n' "$cups_count" >&2
    exit 1
fi

# The single owner still exposes the split rules its reverse dependencies use.
# shellcheck disable=SC2086
$bst --no-interactive -o arch "$arch" show --deps none --format '%{public}' "$cups" > "$work/public"
grep -q cups-libs "$work/public"
grep -q cups-license "$work/public"

# The runtime closure carries no compiler or package manager.
# shellcheck disable=SC2086
$bst --no-interactive -o arch "$arch" show --deps run --format '%{name}' printer-app/core-stack.bst > "$work/runtime"
if grep -E '/(gcc|clang|apt|dpkg|rpm|dnf|flatpak|buildsystem-[^/]*)\.bst$' "$work/runtime"; then
    echo 'Unexpected build tool or package manager in runtime closure' >&2
    exit 1
fi

if [[ ${1:-} == --sources ]]; then
    # shellcheck disable=SC2086
    $bst --no-interactive -o arch "$arch" source checkout --force --directory "$work/cups" "$cups"
    # Cross-junction source checkouts nest under <junction>/<element-path>/.
    cups_source="$work/cups/freedesktop-sdk/components-_private-cups-base"
    grep -q 'getenv("USB_QUIRK_DIR")' "$cups_source/backend/usb-libusb.c"
    grep -q 'browsers = /\*6\*/1' "$cups_source/backend/dnssd.c"

    # Every repository-owned source resolves to an immutable ref, and every
    # queued patch applies to the source it is queued against.
    # shellcheck disable=SC2086
    $bst --no-interactive -o arch "$arch" source checkout --force --directory "$work/pappl" printer-app/pappl.bst
    grep -qE 'PAPPL_MAX_VENDOR[[:space:]]+256' "$work/pappl/pappl/printer.h"
    grep -qE 'log_max_size[[:space:]]+= 0;' "$work/pappl/pappl/system.c"
    grep -q '"cups:socket"' "$work/pappl/pappl/system-webif.c"
fi

printf 'OK: %s printing graph has one CUPS owner and no runtime toolchain\n' "$arch"
