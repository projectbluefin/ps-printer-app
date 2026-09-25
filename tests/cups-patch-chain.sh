#!/usr/bin/env bash
# Proves the shared CUPS patch seam still applies to the pinned freedesktop-sdk
# line: one CUPS provider, intact split rules, and the canonical patches present
# in the checked-out CUPS source.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
arch="${ARCH:-$(uname -m)}"
bst="${BST:-just bst}"
cups_base_target="freedesktop-sdk.bst:components/_private/cups-base.bst"
dependent_target="printer-app/pappl.bst"
source_dir=".bst/cups-patch-chain-source"

# shellcheck disable=SC2086
resolved="$($bst --no-interactive -o arch "$arch" show --deps none --format '%{name}' "$dependent_target")"
if ! grep -qxF "$dependent_target" <<<"$resolved"; then
  printf 'FAIL: expected resolved target %s\n' "$dependent_target" >&2
  printf '%s\n' "$resolved" >&2
  exit 1
fi

# shellcheck disable=SC2086
deps="$($bst --no-interactive -o arch "$arch" show --deps all --format '%{name}' "$dependent_target")"
cups_base_count="$(grep -c '^freedesktop-sdk\.bst:components/_private/cups-base\.bst$' <<<"$deps" || true)"
if [[ "$cups_base_count" != 1 ]]; then
  printf 'FAIL: expected one CUPS base provider, found %s\n' "$cups_base_count" >&2
  exit 1
fi

# shellcheck disable=SC2086
cups_public="$($bst --no-interactive -o arch "$arch" show --deps none --format '%{public}' "$cups_base_target")"
grep -q 'cups-libs' <<<"$cups_public"
grep -q 'cups-license' <<<"$cups_public"

rm -rf "$source_dir"
# shellcheck disable=SC2086
$bst --no-interactive -o arch "$arch" source checkout --force --directory "$source_dir" "$cups_base_target"
cups_source="$source_dir/freedesktop-sdk/components-_private-cups-base"
grep -q 'getenv("USB_QUIRK_DIR")' "$cups_source/backend/usb-libusb.c"
grep -q 'browsers = /\*6\*/1' "$cups_source/backend/dnssd.c"

printf 'OK: patched CUPS graph resolves with one provider, stable split rules, and patched sources\n'
