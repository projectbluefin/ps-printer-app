#!/usr/bin/env bash
#
# Core appliance verification for the ps-printer-app FSDK OCI image.
#
# Starts the built image the way a user does (nonroot, host network, a state
# volume) and checks, from the host:
#   - the web interface answers and the process runs as nonroot 65532:65532;
#   - the entrypoint seeds its state (PPD, spool, CUPS SNMP and USB quirks);
#   - IPP answers: Get-Printer-Attributes on a printer added with the generic
#     PostScript driver and a CUPS socket device;
#   - an IPP Print-Job of a PostScript document is converted by the filter
#     chain, sent by the socket backend to a TCP sink, and completes;
#   - TERM stops the appliance with 143, a dead required child stops it with
#     a failure, seeded state is preserved across runs, and an invalid PORT is
#     rejected with 64.
#
# Physical paper output is not verified: no printer hardware is available.
#
# Environment:
#   IMAGE  image to verify (default ghcr.io/projectbluefin/ps-printer-app:build,
#          the tag `just build` produces)
#   PORT   printer application port (default 18000); the socket sink uses
#          PORT+1000 and the child-failure run PORT+1
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="${IMAGE:-ghcr.io/projectbluefin/ps-printer-app:build}"
name="ps-printer-app-appliance"
failure_name="ps-printer-app-child-failure"
invalid_name="ps-printer-app-invalid-port"
port="${PORT:-18000}"
failure_port="$((port + 1))"
sink_port="$((port + 1000))"
printer="appliance-test"
printer_uri="ipp://127.0.0.1:${port}/ipp/print/${printer}"

state_dir="$(mktemp -d)"
output_file="$(mktemp)"
sink_log="$(mktemp)"
sink_pid=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  podman rm -f "$name" "$failure_name" "$invalid_name" >/dev/null 2>&1 || true
  if [[ -n "$sink_pid" ]]; then
    kill "$sink_pid" >/dev/null 2>&1 || true
    wait "$sink_pid" 2>/dev/null || true
  fi
  podman unshare rm -rf "$state_dir" >/dev/null 2>&1 || true
  rm -rf "$state_dir"
  rm -f "$output_file" "$sink_log"
}
trap cleanup EXIT

wait_for_http() {
  local target_port="$1" response
  for _ in $(seq 1 60); do
    if response="$(curl --fail --silent --show-error "http://127.0.0.1:${target_port}/" 2>/dev/null)" &&
      [[ "$response" == *'<title>PostScript Printer Application</title>'* ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ipp() {
  python3 "$script_dir/ipp-request.py" "$printer_uri" "$@"
}

# First value of one attribute from an ipp-request.py response.
ipp_value() {
  local wanted="$1" line
  while IFS= read -r line; do
    if [[ "$line" == "$wanted="* ]]; then
      line="${line#*=}"
      printf '%s' "${line%%,*}"
      return 0
    fi
  done
  return 1
}

for tool in podman curl python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done
podman image inspect "$image" >/dev/null 2>&1 || fail "image $image not found; run just build first"

echo "== Appliance start and identity =="
chmod 0777 "$state_dir"
podman run -d \
  --name "$name" \
  --network host \
  -e PORT="$port" \
  -v "$state_dir:/var/lib/ps-printer-app:Z" \
  "$image" >/dev/null

if ! wait_for_http "$port"; then
  podman logs "$name" >&2 || true
  fail "the web interface did not answer on port $port"
fi
podman exec "$name" /usr/bin/bash -c '
  set -e
  test "$(id -u):$(id -g)" = 65532:65532
  test "$(id -un)" = nonroot
  passwd_ok=0
  while IFS=: read -r name password uid gid gecos home shell; do
    [[ "$name:$uid:$gid" == "nonroot:65532:65532" ]] && passwd_ok=1
  done < /etc/passwd
  group_ok=0
  while IFS=: read -r name password gid members; do
    [[ "$name:$gid" == "nonroot:65532" ]] && group_ok=1
  done < /etc/group
  (( passwd_ok && group_ok ))
' || fail "the appliance does not run as nonroot 65532:65532"
test -d "$state_dir/ppd" || fail "state: ppd directory missing"
test -d "$state_dir/spool" || fail "state: spool directory missing"
test -d "$state_dir/cups/ssl" || fail "state: cups/ssl directory missing"
test -s "$state_dir/cups/snmp.conf" || fail "state: cups/snmp.conf not seeded"
test -s "$state_dir/usb/org.cups.usb-quirks" || fail "state: usb/org.cups.usb-quirks not seeded"
echo "  ok: web interface answers, nonroot 65532:65532, state seeded"

echo "== IPP printer and a Print-Job through to the socket sink =="
python3 "$script_dir/socket-sink.py" "$sink_port" "$output_file" >"$sink_log" 2>&1 &
sink_pid=$!
sleep 1
podman exec "$name" /usr/bin/ps-printer-app \
  -u "ipp://127.0.0.1:${port}/ipp/system" \
  -d "$printer" \
  -m generic \
  -v "cups:socket://127.0.0.1:${sink_port}" add ||
  fail "could not add printer $printer with the generic driver"

attributes="$(ipp get-printer-attributes)" || fail "Get-Printer-Attributes on $printer_uri failed"
status="$(ipp_value status <<<"$attributes")"
[[ "$status" == 0x0000 ]] || { printf '%s\n' "$attributes" >&2; fail "Get-Printer-Attributes returned $status"; }
model="$(ipp_value printer-make-and-model <<<"$attributes")" || model=""
[[ "$model" == "Generic PostScript Printer" ]] ||
  fail "printer-make-and-model is '$model', expected 'Generic PostScript Printer'"
formats="$(grep '^document-format-supported=' <<<"$attributes" || true)"
[[ "$formats" == *application/postscript* ]] || fail "application/postscript is not a supported document format: $formats"
echo "  ok: IPP Get-Printer-Attributes answers for $printer ($model)"

response="$(ipp print-job "$script_dir/../testpage.ps" application/postscript)" || fail "Print-Job failed"
status="$(ipp_value status <<<"$response")"
job_id="$(ipp_value job-id <<<"$response")" || job_id=""
if [[ "$status" != 0x0000 && "$status" != 0x0001 ]] || [[ ! "$job_id" =~ ^[0-9]+$ ]]; then
  printf '%s\n' "$response" >&2
  fail "Print-Job returned status $status and job-id '$job_id'"
fi
echo "  ok: IPP Print-Job accepted as job $job_id"

job_state=""
for _ in $(seq 1 120); do
  job_state="$(ipp get-job-attributes "$job_id" | ipp_value job-state)" || job_state=""
  # 9 completed, 7 canceled, 8 aborted (RFC 8011, section 5.3.7)
  [[ "$job_state" == 7 || "$job_state" == 8 || "$job_state" == 9 ]] && break
  sleep 0.5
done
if [[ "$job_state" != 9 ]]; then
  podman logs "$name" >&2 || true
  cat "$sink_log" >&2 || true
  fail "job $job_id ended in job-state '$job_state', expected 9 (completed)"
fi
for _ in $(seq 1 20); do
  kill -0 "$sink_pid" 2>/dev/null || break
  sleep 0.5
done
[[ -s "$output_file" ]] || { cat "$sink_log" >&2; fail "the socket sink received no data"; }
prefix="$(head -c 512 -- "$output_file" | tr -d '\000')"
[[ "$prefix" == *'%!PS-Adobe'* ]] || fail "the socket sink received no PostScript page description"
echo "  ok: job $job_id completed, $(wc -c <"$output_file") PostScript bytes reached the socket sink"

echo "== Lifecycle =="
podman exec "$name" /usr/bin/bash -c 'printf "%s\n" "# preserved" > /var/lib/ps-printer-app/cups/snmp.conf'
podman exec "$name" /usr/bin/bash -c 'printf "%s\n" "# preserved USB quirks" > /var/lib/ps-printer-app/usb/org.cups.usb-quirks'
podman stop --time 15 "$name" >/dev/null
read -r running exit_status <<<"$(podman inspect "$name" --format '{{.State.Running}} {{.State.ExitCode}}')"
if [[ "$running" != false || "$exit_status" -ne 143 ]]; then
  podman logs "$name" >&2
  fail "TERM shutdown ended in state $running with status $exit_status, expected false 143"
fi
echo "  ok: TERM stops the appliance with 143"

podman run -d \
  --name "$failure_name" \
  --network host \
  -e PORT="$failure_port" \
  -v "$state_dir:/var/lib/ps-printer-app:Z" \
  "$image" >/dev/null
wait_for_http "$failure_port" || { podman logs "$failure_name" >&2; fail "restart on port $failure_port did not answer"; }
podman exec "$failure_name" /usr/bin/bash -c 'test "$(< /var/lib/ps-printer-app/cups/snmp.conf)" = "# preserved"' ||
  fail "the entrypoint overwrote the persisted snmp.conf"
podman exec "$failure_name" /usr/bin/bash -c 'test "$(< /var/lib/ps-printer-app/usb/org.cups.usb-quirks)" = "# preserved USB quirks"' ||
  fail "the entrypoint overwrote the persisted USB quirks"
echo "  ok: persisted state is preserved across runs"
podman exec "$failure_name" /usr/bin/bash -c '
  for proc in /proc/[0-9]*; do
    read -r comm < "$proc/comm" || continue
    if [[ "$comm" == avahi-daemon ]]; then
      kill -TERM "${proc##*/}"
      exit 0
    fi
  done
  exit 1
' || fail "no avahi-daemon runs in the appliance"
for _ in $(seq 1 150); do
  [[ "$(podman inspect "$failure_name" --format '{{.State.Running}}')" == false ]] && break
  sleep 0.1
done
read -r running failure_status <<<"$(podman inspect "$failure_name" --format '{{.State.Running}} {{.State.ExitCode}}')"
if [[ "$running" != false ]]; then
  podman logs "$failure_name" >&2
  fail "container stayed running after a required child died"
fi
[[ "$failure_status" -ne 0 ]] || fail "required child failure returned success"
echo "  ok: a dead required child stops the appliance with status $failure_status"

set +e
podman run --name "$invalid_name" -e PORT=invalid "$image" >/dev/null 2>&1
invalid_status=$?
set -e
[[ "$invalid_status" -eq 64 ]] || fail "invalid PORT exited $invalid_status instead of 64"
podman logs "$invalid_name" 2>&1 | grep -q 'PORT must be numeric' || fail "invalid PORT diagnostic missing"
echo "  ok: an invalid PORT is rejected with 64"

printf 'PASS: %s answers IPP, prints to a socket and passes lifecycle verification\n' "$image"
