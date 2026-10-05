#!/usr/bin/env bash
# Regression test for expect_refusal log matching pattern in tests/instance-isolation.sh.
#
# When a container logs multiple lines (e.g. unrecognized PRINTER_APP_SERVER_OPTIONS
# followed by the allowed options list), piping "podman logs | grep -q" under
# "set -euo pipefail" risks early exit of grep -q causing SIGPIPE (exit code 141)
# on the logging process, making the pipeline fail despite a successful match.
#
# The helper must buffer logs first into a variable before matching with grep -qF
# to avoid SIGPIPE while preserving exact diagnostic verification and exit 64 semantics.
set -euo pipefail

failures=0

report() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# The buffer-first matching function under test (identical to tests/instance-isolation.sh)
match_refusal_log() {
  local label="$1" diagnostic="$2" logs="$3"
  if ! grep -qF -- "$diagnostic" <<<"$logs"; then
    report "$label: diagnostic '$diagnostic' missing in logs: $logs"
    return 1
  fi
  printf 'ok: %s\n' "$label"
  return 0
}

# 1. Multi-line output matching line 1
multiline_logs="PRINTER_APP_SERVER_OPTIONS: unrecognized option \"bogus-option\"
Valid options are: none dnssd-host no-multi-queue raw-socket usb-printer no-web-interface web-log web-network web-remote web-security no-tls"

match_refusal_log \
  "multi-line log with match on line 1" \
  'unrecognized option "bogus-option"' \
  "$multiline_logs"

# 2. Multi-line output matching line 2
match_refusal_log \
  "multi-line log with match on line 2" \
  "Valid options are: none dnssd-host" \
  "$multiline_logs"

# 3. Single-line log output
match_refusal_log \
  "single-line log match" \
  "PORT must be between 1 and 65535" \
  "PORT must be between 1 and 65535"

# 4. Multi-line output from simulated streaming process (preventing SIGPIPE under pipefail)
streaming_producer() {
  python3 -c '
import sys, time
sys.stdout.write("PRINTER_APP_SERVER_OPTIONS: unrecognized option \"bogus-option\"\n")
sys.stdout.flush()
time.sleep(0.01)
sys.stdout.write("Valid options are: none dnssd-host\n")
sys.stdout.flush()
'
}

captured_logs="$(streaming_producer 2>&1)"
match_refusal_log \
  "streaming producer logs buffered without SIGPIPE" \
  'unrecognized option "bogus-option"' \
  "$captured_logs"

# 5. Missing diagnostic must be detected and report failure
missing_detected=0
if ! grep -qF -- "completely-absent-string" <<<"$multiline_logs"; then
  missing_detected=1
fi
if [ "$missing_detected" -eq 1 ]; then
  printf 'ok: missing diagnostic correctly detected and rejected\n'
else
  report "missing diagnostic was unexpectedly accepted"
fi

if [ "$failures" -ne 0 ]; then
  printf '%s check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'All expect_refusal helper regression checks passed\n'
