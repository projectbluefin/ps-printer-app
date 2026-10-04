#!/usr/bin/env bash
# Exercise the PRINTER_APP_AUTH_SERVICE / PRINTER_APP_ADMIN_GROUP /
# PRINTER_APP_SERVER_OPTIONS validation at the top of
# files/container-entrypoint.sh without building or running the OCI image.
#
# ChairLift ADR-0016 requires that the web admin interface is either
# authenticated or explicitly disabled, never silently open. These checks
# must fail closed (non-zero exit) on any malformed or unknown value instead
# of falling through to an unauthenticated server start.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
entrypoint="$root/files/container-entrypoint.sh"

# Extract prologue before state_dir setup so checks run on host without root or state mount.
prologue="$(sed '/^state_dir=/,$d' "$entrypoint")"
prologue="$prologue"$'\n'"printf '%s\n' \"\${server_options:-}\""

failures=0

report() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

run() {
  local label="$1" want_status="$2" want_output="$3"
  shift 3
  local status=0 output
  output="$(env -i PATH="$PATH" "$@" bash -c "$prologue" 2>&1)" || status=$?
  if [ "$status" != "$want_status" ]; then
    report "$label: exit status $status, expected $want_status (output: $output)"
    return
  fi
  if ! grep -qF -- "$want_output" <<<"$output"; then
    report "$label: output '$output', expected '$want_output'"
    return
  fi
  printf 'ok: %s\n' "$label"
}

run 'no auth env set adds nothing' 0 ''

run 'auth service with unsafe characters is rejected' \
  64 'PRINTER_APP_AUTH_SERVICE must be 1-64 characters of letters, digits, "-" or "_"' \
  PRINTER_APP_AUTH_SERVICE='has space'

run 'auth service path traversal is rejected' \
  64 'PRINTER_APP_AUTH_SERVICE must be 1-64 characters of letters, digits, "-" or "_"' \
  PRINTER_APP_AUTH_SERVICE='../shadow'

run 'auth service cups is refused while PAPPL lacks PAM' \
  64 'PRINTER_APP_AUTH_SERVICE=cups cannot be honoured: PAPPL is built without PAM in this image' \
  PRINTER_APP_AUTH_SERVICE=cups

run 'malformed admin group is rejected' \
  64 'PRINTER_APP_ADMIN_GROUP must be a valid Unix group name' \
  PRINTER_APP_ADMIN_GROUP='Not Valid'

run 'admin group that does not exist is rejected' \
  64 'PRINTER_APP_ADMIN_GROUP=no-such-group does not exist' \
  PRINTER_APP_ADMIN_GROUP=no-such-group

run 'admin group root without auth service is refused' \
  64 'PRINTER_APP_ADMIN_GROUP requires PRINTER_APP_AUTH_SERVICE' \
  PRINTER_APP_ADMIN_GROUP=root

run 'no-web-interface is accepted' \
  0 'no-web-interface' \
  PRINTER_APP_SERVER_OPTIONS=no-web-interface

run 'multiple valid server options are accepted' \
  0 'no-web-interface,web-log' \
  PRINTER_APP_SERVER_OPTIONS=no-web-interface,web-log

run 'unrecognized server option is rejected' \
  64 'PRINTER_APP_SERVER_OPTIONS: unrecognized option "bogus-option"' \
  PRINTER_APP_SERVER_OPTIONS=bogus-option

if [ "$failures" -ne 0 ]; then
  printf '%s check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'All auth-service/admin-group/server-options validation checks passed\n'
