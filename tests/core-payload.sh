#!/usr/bin/env bash
#
# Core driver and PPD payload verification for the ps-printer-app OCI image.
#
# This is the verification half of the payload contract: it inspects a real
# image, not repository source text, for the driver, filter, backend and PPD
# payload that upstream ps-printer-app promises, and then sends a real print job
# through the IPP entry point, the PDF to PostScript filter and the socket
# backend, checking the bytes that reach the printer with a TCP socket sink.
#
# Usage:
#   tests/core-payload.sh             verify one image end to end
#   tests/core-payload.sh --in-image  payload inventory only, run inside the image
#
# Environment:
#   IMAGE       image reference to verify
#               (default ghcr.io/projectbluefin/ps-printer-app:latest)
#   RUNTIME     container runtime (default podman)
#   PORT        printer application port (default 18020), the sink uses PORT+1000
#   MIN_DRIVERS floor for the number of drivers the application must enumerate
#               (default 1000, see the note below)
#   IMAGE_PULL  set to 1 to pull IMAGE even when it already exists locally
#
# What this can and cannot claim: it proves that the payload is present and
# usable and that a submitted job traverses IPP, the conversion filter and the
# socket backend and completes.  Physical paper output is not verified, because
# no printer hardware is available.
#
# The MIN_DRIVERS floor exists so that the manufacturer PPD archives have to be
# enumerated by the application and not just the built-in generic PPD: the
# README promises the order of ten thousand PostScript PPDs from Foomatic and
# HPLIP, so a thousand is a deliberately loose floor.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="$script_dir/payload-manifest.txt"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

# ---------------------------------------------------------------------------
# In-image payload inventory
# ---------------------------------------------------------------------------

# Resolve the runtime closure of one executable: shared libraries for an ELF
# binary, the interpreter for a script.
check_closure() {
  local path="$1" provenance="$2" magic shebang interpreter ldd_output

  magic="$(od -An -tx1 -N4 -- "$path" | tr -d ' \n')"
  if [[ "$magic" == "7f454c46" ]]; then
    if ! ldd_output="$(ldd -- "$path" 2>&1)"; then
      printf '%s\n' "$ldd_output" >&2
      fail "ldd failed for $path ($provenance)"
    fi
    if [[ "$ldd_output" == *"not found"* ]]; then
      printf '%s\n' "$ldd_output" >&2
      fail "unresolved shared library in $path ($provenance)"
    fi
  elif [[ "$magic" == 2321* ]]; then
    shebang="$(head -n 1 -- "$path")"
    interpreter="${shebang#\#!}"
    interpreter="${interpreter#"${interpreter%%[![:space:]]*}"}"
    interpreter="${interpreter%% *}"
    if [[ -z "$interpreter" ]]; then
      fail "no interpreter in the shebang of $path ($provenance)"
    fi
    if [[ ! -x "$interpreter" ]]; then
      fail "$path needs the missing interpreter $interpreter ($provenance)"
    fi
  else
    fail "$path is neither an ELF binary nor a script ($provenance)"
  fi
}

# Sample a pyppd self-extracting archive: the first, middle and last PPD have to
# extract to PostScript.  A single-entry check passes on a truncated archive.
check_archive() {
  local path="$1" provenance="$2" entries=() index uri ppd

  mapfile -t entries < <("$path" list)
  if (( ${#entries[@]} == 0 )); then
    fail "PPD archive lists no PPDs: $path ($provenance)"
  fi

  for index in 0 $(( ${#entries[@]} / 2 )) $(( ${#entries[@]} - 1 )); do
    uri="${entries[$index]%% *}"
    uri="${uri#\"}"
    uri="${uri%\"}"
    ppd="$("$path" cat "$uri")"
    if [[ "$ppd" != *"*PPD-Adobe:"* ]]; then
      fail "PPD archive entry '$uri' of $path is not a PostScript PPD ($provenance)"
    fi
  done

  ppd_archive_entries=$(( ppd_archive_entries + ${#entries[@]} ))
  note "  ok: $path - ${#entries[@]} PPDs, sampled entries are PostScript"
}

check_payload() {
  local kind path provenance tool
  local executables=0 archives=0
  ppd_archive_entries=0

  for tool in ldd od tr grep head; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      fail "$tool is missing from the image, so the payload inventory cannot be checked"
    fi
  done

  [[ -f "$manifest" ]] || fail "payload manifest not found: $manifest"

  while read -r kind path provenance; do
    if [[ -z "$kind" ]]; then
      continue
    fi
    if [[ "$kind" == \#* ]]; then
      continue
    fi
    if [[ -z "$path" ]]; then
      fail "manifest entry without a path: $kind"
    fi

    case "$kind" in
      executable)
        [[ -f "$path" ]] || fail "missing payload executable: $path ($provenance)"
        [[ -x "$path" ]] || fail "payload file is not executable: $path ($provenance)"
        check_closure "$path" "$provenance"
        executables=$(( executables + 1 ))
        ;;
      ppd)
        [[ -s "$path" ]] || fail "missing or empty PPD file: $path ($provenance)"
        if ! grep -q '\*PPD-Adobe:' -- "$path"; then
          fail "$path has no *PPD-Adobe: header ($provenance)"
        fi
        ;;
      file)
        [[ -s "$path" ]] || fail "missing or empty payload file: $path ($provenance)"
        ;;
      archive)
        [[ -x "$path" ]] || fail "PPD archive is not executable: $path ($provenance)"
        check_archive "$path" "$provenance"
        archives=$(( archives + 1 ))
        ;;
      *)
        fail "unknown payload kind '$kind' for $path"
        ;;
    esac
  done < "$manifest"

  if (( executables == 0 || archives == 0 )); then
    fail "the payload manifest $manifest declared no executables or no PPD archives"
  fi

  note "  ok: $executables executables with a resolved closure, $archives PPD archives, $ppd_archive_entries archive PPDs"
}

if [[ "${1:-}" == "--in-image" ]]; then
  if [[ $# -ne 1 ]]; then
    fail "--in-image does not take further arguments"
  fi
  check_payload
  exit 0
fi
if [[ $# -ne 0 ]]; then
  fail "unexpected argument: $1"
fi

# ---------------------------------------------------------------------------
# Host orchestration: real image, real IPP job, real socket backend
# ---------------------------------------------------------------------------

image="${IMAGE:-ghcr.io/projectbluefin/ps-printer-app:latest}"
runtime="${RUNTIME:-podman}"
name="${NAME:-ps-printer-app-payload}"
port="${PORT:-18020}"
min_drivers="${MIN_DRIVERS:-1000}"
sink_port=$(( port + 1000 ))

printer="core-test"
driver="generic"
make_and_model="Generic PostScript Printer"
system_page_title="<title>PostScript Printer Application</title>"

state_dir="$(mktemp -d)"
in_image_dir="$(mktemp -d)"
output_file="$(mktemp)"
cookie_file="$(mktemp)"
sink_log="$(mktemp)"
sink_pid=""

cleanup() {
  "$runtime" rm --force "$name" >/dev/null 2>&1 || true
  if [[ -n "$sink_pid" ]]; then
    kill "$sink_pid" >/dev/null 2>&1 || true
    wait "$sink_pid" 2>/dev/null || true
  fi
  if [[ "$runtime" == podman ]]; then
    "$runtime" unshare rm -rf "$state_dir" >/dev/null 2>&1 || true
  fi
  rm -rf "$state_dir" "$in_image_dir" >/dev/null 2>&1 || true
  rm -f "$output_file" "$cookie_file" "$sink_log"
}
trap cleanup EXIT

wait_ready() {
  local http https
  for _ in $(seq 1 60); do
    http="$(curl --fail --silent --show-error "http://127.0.0.1:${port}/" 2>/dev/null || true)"
    https="$(curl --insecure --fail --silent --show-error "https://127.0.0.1:${port}/" 2>/dev/null || true)"
    if [[ "$http" == *"$system_page_title"* && "$https" == *"$system_page_title"* ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Fetch the printer's web page, retrying while the application settles.  The
# page carries the make and model of the selected driver, which is the driver
# selection evidence.
fetch_printer_page() {
  local page=""
  for _ in $(seq 1 20); do
    page="$(curl --fail --silent --show-error "$@" "http://127.0.0.1:${port}/${printer}/" 2>/dev/null || true)"
    if [[ "$page" == *"$make_and_model"* ]]; then
      printf '%s' "$page"
      return 0
    fi
    sleep 0.5
  done
  printf '%s' "$page"
  return 1
}

for tool in "$runtime" curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    fail "required tool not found: $tool"
  fi
done
[[ -r "$manifest" ]] || fail "payload manifest not found: $manifest"
[[ -r "$script_dir/socket-sink.py" ]] || fail "socket sink not found: $script_dir/socket-sink.py"

if [[ "${IMAGE_PULL:-0}" == 1 ]] || ! "$runtime" image inspect "$image" >/dev/null 2>&1; then
  note "Pulling $image"
  "$runtime" pull "$image" || fail "unable to obtain image $image"
fi

note "== Payload inventory in $image =="
cp "$script_dir/core-payload.sh" "$script_dir/payload-manifest.txt" "$in_image_dir/"
chmod 0755 "$in_image_dir/core-payload.sh"
chmod 0644 "$in_image_dir/payload-manifest.txt"
"$runtime" run --rm --entrypoint /usr/bin/bash \
  --volume "$in_image_dir:/tests:ro,Z" \
  "$image" /tests/core-payload.sh --in-image

note "== Real IPP print path through the socket backend =="
chmod 0777 "$state_dir"
python3 "$script_dir/socket-sink.py" "$sink_port" "$output_file" >"$sink_log" 2>&1 &
sink_pid=$!
sleep 1

"$runtime" run --detach --name "$name" --network host \
  --env "PORT=$port" \
  --volume "$state_dir:/var/lib/ps-printer-app:Z" \
  "$image" >/dev/null

if ! wait_ready; then
  "$runtime" logs "$name" >&2 || true
  fail "the printer application did not serve HTTP and HTTPS on port $port"
fi
note "  ok: HTTP and HTTPS serve the printer application"

system_uri="ipp://127.0.0.1:${port}/ipp/system"
printer_uri="ipp://127.0.0.1:${port}/ipp/print/${printer}"

drivers="$("$runtime" exec "$name" /usr/bin/ps-printer-app drivers)"
if [[ "$drivers" != *'"Generic Printer"'* ]]; then
  printf '%s\n' "$drivers" >&2
  fail "the application does not offer the generic PostScript driver"
fi
driver_count="$(grep -c . <<<"$drivers")"
if (( driver_count < min_drivers )); then
  printf '%s\n' "$drivers" >&2
  fail "the application enumerates only $driver_count drivers, expected at least $min_drivers"
fi
note "  ok: $driver_count drivers enumerated, including the generic PostScript driver"

if ! "$runtime" exec "$name" /usr/bin/ps-printer-app \
  -u "$system_uri" \
  -d "$printer" \
  -m "$driver" \
  -v "cups:socket://127.0.0.1:${sink_port}" add; then
  fail "could not add printer $printer with the $driver driver"
fi

if ! printer_page="$(fetch_printer_page --cookie-jar "$cookie_file")"; then
  fail "printer $printer does not report $make_and_model, so the $driver driver was not selected"
fi
session="${printer_page#*name=\"session\" value=\"}"
session="${session%%\"*}"
if [[ -z "$session" || "$session" == "$printer_page" ]]; then
  fail "the printer page carries no web interface session token"
fi
note "  ok: printer $printer selected the $driver driver and points at the socket sink"

curl --fail --silent --show-error \
  --cookie "$cookie_file" \
  --data-urlencode "session=$session" \
  --data 'action=print-test-page' \
  "http://127.0.0.1:${port}/${printer}/" >/dev/null

for _ in $(seq 1 120); do
  if [[ -s "$output_file" ]]; then
    break
  fi
  sleep 0.5
done
if [[ ! -s "$output_file" ]]; then
  "$runtime" exec "$name" /usr/bin/ps-printer-app -u "$printer_uri" jobs >&2 || true
  "$runtime" exec "$name" cat /ps-printer-app.log >&2 || true
  cat "$sink_log" >&2 || true
  fail "the print job produced no output on the socket sink"
fi

prefix="$(head -c 512 -- "$output_file" | tr -d '\000')"
if [[ "$prefix" != *'%!PS-Adobe'* ]]; then
  printf 'first bytes: %s\n' "$(head -c 32 -- "$output_file" | od -An -tx1 | tr -d '\n')" >&2
  cat "$sink_log" >&2 || true
  fail "the captured output carries no PostScript page description"
fi
note "  ok: $(wc -c <"$output_file") bytes captured on the socket sink, PostScript header present"

jobs_output=""
for _ in $(seq 1 120); do
  jobs_output="$("$runtime" exec "$name" /usr/bin/ps-printer-app -u "$printer_uri" jobs)"
  if [[ "$jobs_output" == *"completed"* ]]; then
    break
  fi
  sleep 0.5
done
if [[ "$jobs_output" != *"completed"* ]]; then
  printf '%s\n' "$jobs_output" >&2
  fail "the print job never reached the completed state"
fi
note "  ok: the job reached the completed state"

# Wait briefly for the sink to finish reading, then keep whatever arrived.
for _ in $(seq 1 20); do
  if ! kill -0 "$sink_pid" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

note "== Restart persistence =="
"$runtime" restart "$name" >/dev/null
if ! wait_ready; then
  "$runtime" logs "$name" >&2 || true
  fail "the printer application did not come back after a restart"
fi
if ! "$runtime" exec "$name" /usr/bin/ps-printer-app -u "$printer_uri" jobs >/dev/null; then
  fail "printer $printer did not survive the restart"
fi
if ! printer_page="$(fetch_printer_page)"; then
  fail "after the restart printer $printer no longer reports $make_and_model"
fi
if [[ -z "$(find "$state_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  fail "the persisted state directory $state_dir is empty after the restart"
fi
note "  ok: printer, driver selection and state survived a restart"
note "  persisted state: $(find "$state_dir" -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)"

note "PASS: $image ships the PostScript driver and PPD payload and prints through the IPP, filter and socket backend"
