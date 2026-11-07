#!/usr/bin/env bash
# Run files/container-entrypoint.sh itself on the host and check how it drives
# the shared printing-base startup library: validation runs first and refuses
# before any state is touched, the state volume and CUPS seeding get this
# appliance's paths, the app-specific environment is exported, and the
# validated options reach ps-printer-app. entrypoint-validation.sh and
# entrypoint-port.sh test the library's validation; this tests the wrapper.
#
# The real library is sourced. Only the steps that need the image or root
# (state preparation, CUPS seeding, mkdir under /run, the supervisor) are
# replaced by recorders, after the library has defined them.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
entrypoint="$script_dir/../files/container-entrypoint.sh"
source "$script_dir/source-printing-base.sh"

work="$(mktemp -d)"
# This replaces source-printing-base.sh's EXIT trap, so remove the library it
# downloaded too (never a local copy named by PRINTER_APP_ENTRYPOINT_COMMON).
trap 'rm -rf "$work"; [[ -n "${PRINTER_APP_ENTRYPOINT_COMMON:-}" ]] || rm -f "$LIB"' EXIT
failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Point the entrypoint's one library source line at the shim, and refuse to run
# a copy where that line was not found exactly once.
library_line='source /usr/libexec/printer-app/entrypoint-common.sh'
if [[ "$(grep -cxF -- "$library_line" "$entrypoint")" != 1 ]]; then
  printf 'FAIL: %s must contain exactly one line: %s\n' "$entrypoint" "$library_line" >&2
  exit 1
fi
awk -v line="$library_line" '$0 == line { print "source \"$SHIM\""; next } { print }' \
  "$entrypoint" > "$work/entrypoint.sh"

cat > "$work/shim.sh" <<'SHIM'
source "$LIB"
record() { printf '%s\n' "$*" >> "$CALLS"; }
eval "real_$(declare -f printer_app_validate)"
printer_app_validate() { record validate "$@"; real_printer_app_validate "$@"; }
printer_app_prepare_state() { record prepare_state "$@"; }
printer_app_seed_cups() { record seed_cups "$@"; }
mkdir() { record mkdir "$@"; }
printer_app_supervise() {
  record supervise "$@"
  local name
  for name in BACKEND_DIR CUPS_SERVERBIN CUPS_SERVERROOT FILTER_DIR PPD_PATHS \
    SPOOL_DIR STATE_DIR STATE_FILE TESTPAGE_DIR TMPDIR USB_QUIRK_DIR; do
    record "env $name=${!name-<unset>}"
  done
  [[ ":$PATH:" == *":$FILTER_DIR:"* ]] && record 'env PATH has FILTER_DIR'
}
SHIM

# run_entrypoint NAME=VALUE...: runs the wrapper in a clean environment and
# leaves its exit status in $status, its stderr in $output and the recorded
# calls in $calls.
run_entrypoint() {
  : > "$work/calls"
  status=0
  output="$(env -i PATH="$PATH" LIB="$LIB" SHIM="$work/shim.sh" CALLS="$work/calls" "$@" \
    bash "$work/entrypoint.sh" 2>&1 >/dev/null)" || status=$?
  calls="$(cat "$work/calls")"
}

expect_calls() {
  local label="$1" want="$2"
  if [[ "$calls" != "$want" ]]; then
    fail "$label: recorded calls differ"
    diff <(printf '%s\n' "$want") <(printf '%s\n' "$calls") >&2 || true
  else
    printf 'ok: %s\n' "$label"
  fi
}

state=/var/lib/ps-printer-app
app_env="env BACKEND_DIR=/usr/lib/ps-printer-app/backend
env CUPS_SERVERBIN=/usr/lib/ps-printer-app
env CUPS_SERVERROOT=$state/cups
env FILTER_DIR=/usr/lib/ps-printer-app/filter
env PPD_PATHS=%s
env SPOOL_DIR=$state/spool
env STATE_DIR=$state
env STATE_FILE=$state/ps-printer-app.state
env TESTPAGE_DIR=/usr/share/ps-printer-app
env TMPDIR=/tmp
env USB_QUIRK_DIR=$state
env PATH has FILTER_DIR"
startup="validate PostScript Printer Application
prepare_state $state ps-printer-app
seed_cups $state
mkdir -p /run/ps-printer-app"

run_entrypoint
[[ "$status" == 0 ]] || fail "defaults: exit status $status (output: $output)"
# shellcheck disable=SC2059 # app_env is the format, PPD_PATHS its one field.
expect_calls 'defaults: library steps in order, app paths exported' "$startup
supervise /run ps-printer-app -o log-file=$state/ps-printer-app.log server
$(printf "$app_env" "/usr/share/ppd/:$state/ppd/")"
[[ "$output" == *'NOTICE: web administration is reachable'* ]] \
  || fail "defaults: no web-administration NOTICE (output: $output)"

run_entrypoint PORT=018020 PRINTER_APP_SERVER_OPTIONS=no-web-interface \
  PRINTER_APP_INSTANCE='office 1' PPD_PATHS=/srv/ppd
[[ "$status" == 0 ]] || fail "options: exit status $status (output: $output)"
# shellcheck disable=SC2059
expect_calls 'options: validated settings reach ps-printer-app, PPD_PATHS kept' "$startup
supervise /run ps-printer-app -o log-file=$state/ps-printer-app.log -o server-port=18020 -o server-options=no-web-interface -o system-name='PostScript Printer Application (office-1)' server
$(printf "$app_env" /srv/ppd)"
[[ "$output" != *NOTICE* ]] || fail "options: NOTICE with the web interface off (output: $output)"

# Refusals must stop the wrapper before it touches state or starts anything.
expect_refusal() {
  local want_status="$1" want_message="$2"
  shift 2
  run_entrypoint "$@"
  if [[ "$status" != "$want_status" || "$output" != *"$want_message"* ]]; then
    fail "$*: exit status $status, expected $want_status with '$want_message' (output: $output)"
    return
  fi
  expect_calls "$* refused with $want_status before any state" 'validate PostScript Printer Application'
}

expect_refusal 64 'PORT must be numeric' PORT=invalid
expect_refusal 64 'PRINTER_APP_INSTANCE must contain' PRINTER_APP_INSTANCE='-!-'
expect_refusal 64 "unsupported option 'no-tls'" PRINTER_APP_SERVER_OPTIONS=no-tls
expect_refusal 78 'cannot be honoured' PRINTER_APP_AUTH_SERVICE=cups
expect_refusal 78 'requires PRINTER_APP_AUTH_SERVICE' PRINTER_APP_ADMIN_GROUP=wheel

if ((failures > 0)); then
  printf 'FAIL: %d entrypoint wiring check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'OK: the entrypoint drives the shared startup library as the image expects\n'
