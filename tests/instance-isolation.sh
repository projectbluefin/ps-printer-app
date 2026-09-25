#!/usr/bin/env bash
#
# Instance isolation verification for the ps-printer-app FSDK OCI image.
#
# Starts the built image the way a user runs several Printer Applications on
# one host (nonroot, host network, one PORT, state volume and
# PRINTER_APP_INSTANCE each) and checks, from the host:
#   - two instances with distinct PORT and PRINTER_APP_INSTANCE both serve,
#     report distinct, sanitized system names over IPP Get-System-Attributes
#     and in the web interface, and each registers its own name for DNS-SD
#     (_ipps-system._tcp) with its avahi-daemon;
#   - an instance without PRINTER_APP_INSTANCE keeps the built-in name;
#   - the entrypoint refuses, with 64, a PRINTER_APP_INSTANCE that sanitizes
#     to nothing, a PORT outside 1-65535, and a state volume the image user
#     cannot write (printing the podman unshare chown that fixes it).
#
# Discovery by another host and USB device ownership are not verified here.
#
# Environment:
#   IMAGE        image to verify (default ghcr.io/projectbluefin/ps-printer-app:build)
#   PORT         first application port (default 18080); PORT..PORT+2 are used
#   NAME_PREFIX  container name prefix (default ps-printer-app-inst)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="${IMAGE:-ghcr.io/projectbluefin/ps-printer-app:build}"
prefix="${NAME_PREFIX:-ps-printer-app-inst}"
port="${PORT:-18080}"
default_name="PostScript Printer Application"
# A per-run suffix keeps the advertised names of concurrent runs apart.
suffix="$(printf '%04x' "$((RANDOM % 65536))")"

# name port PRINTER_APP_INSTANCE expected-system-name, one row per instance.
# a: spaces and punctuation become one hyphen, the ends are trimmed.
# b: an identity longer than 24 characters is capped.
b_instance="b_${suffix}-0123456789abcdefghijklmnop"
instances=(
  "a|$port|  Lab A!!  ${suffix}  |$default_name (Lab-A-${suffix})"
  "b|$((port + 1))|${b_instance}|$default_name (${b_instance:0:24})"
  "default|$((port + 2))||$default_name"
)

containers=()
state_dirs=()

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local dir
  if ((${#containers[@]})); then
    podman rm -f "${containers[@]}" >/dev/null 2>&1 || true
  fi
  for dir in "${state_dirs[@]}"; do
    podman unshare rm -rf "$dir" >/dev/null 2>&1 || true
    rm -rf "$dir"
  done
}
trap cleanup EXIT

# Sets state_dir to a new temporary directory that cleanup removes.
new_state_dir() {
  state_dir="$(mktemp -d)"
  state_dirs+=("$state_dir")
}

# First value of one attribute from an ipp-request.py response.
ipp_value() {
  local wanted="$1" line
  while IFS= read -r line; do
    if [[ "$line" == "$wanted="* ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done
  return 1
}

# Web interface title, once it answers on the port.
wait_for_title() {
  local target_port="$1" expected="$2" response
  for _ in $(seq 1 60); do
    if response="$(curl --fail --silent --show-error "http://127.0.0.1:${target_port}/" 2>/dev/null)" &&
      [[ "$response" == *"<title>${expected}</title>"* ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# avahi-browse -p escapes a service name's space and parentheses as decimal
# \DDD; the sanitized instance identity needs no other escape.
dnssd_escape() {
  local name="$1"
  name="${name// /\\032}"
  name="${name//(/\\040}"
  printf '%s' "${name//)/\\041}"
}

# Expect the entrypoint to refuse a configuration with 64 and a diagnostic.
expect_refusal() {
  local label="$1" diagnostic="$2" name status
  shift 2
  name="${prefix}-refused-${#containers[@]}"
  containers+=("$name")
  set +e
  podman run --name "$name" "$@" "$image" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 64 ]] || { podman logs "$name" >&2 || true; fail "$label exited $status instead of 64"; }
  podman logs "$name" 2>&1 | grep -qF -- "$diagnostic" ||
    { podman logs "$name" >&2 || true; fail "$label: diagnostic '$diagnostic' missing"; }
  echo "  ok: $label is refused with 64"
}

for tool in podman curl python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done
podman image inspect "$image" >/dev/null 2>&1 || fail "image $image not found; run just build first"

echo "== Instances with their own port, state volume and name =="
for row in "${instances[@]}"; do
  IFS='|' read -r id instance_port instance expected <<<"$row"
  name="${prefix}-${id}"
  new_state_dir
  chmod 0777 "$state_dir"
  containers+=("$name")
  instance_env=()
  [[ -z "$instance" ]] || instance_env=(-e "PRINTER_APP_INSTANCE=$instance")
  podman run -d \
    --name "$name" \
    --network host \
    -e PORT="$instance_port" \
    "${instance_env[@]}" \
    -v "$state_dir:/var/lib/ps-printer-app:Z" \
    "$image" >/dev/null
done

seen_names=()
for row in "${instances[@]}"; do
  IFS='|' read -r id instance_port instance expected <<<"$row"
  name="${prefix}-${id}"
  if ! wait_for_title "$instance_port" "$expected"; then
    podman logs "$name" >&2 || true
    fail "$name: the web interface on port $instance_port does not answer with the title '$expected'"
  fi
  attributes="$(python3 "$script_dir/ipp-request.py" "ipp://127.0.0.1:${instance_port}/ipp/system" get-system-attributes)" ||
    fail "$name: Get-System-Attributes on port $instance_port failed"
  status="$(ipp_value status <<<"$attributes")"
  [[ "$status" == 0x0000 ]] || { printf '%s\n' "$attributes" >&2; fail "$name: Get-System-Attributes returned $status"; }
  system_name="$(ipp_value system-name <<<"$attributes")" || system_name=""
  [[ "$system_name" == "$expected" ]] || fail "$name: system-name is '$system_name', expected '$expected'"
  for seen in "${seen_names[@]}"; do
    [[ "$seen" != "$system_name" ]] || fail "$name: system-name '$system_name' is not unique"
  done
  seen_names+=("$system_name")
  echo "  ok: $name serves port $instance_port as '$system_name'"
done

# Only the named instances: the default name may already be advertised by
# another application on the network, which this test does not own. The
# resolved service must point at the instance's own port.
for row in "${instances[@]:0:2}"; do
  IFS='|' read -r id instance_port instance expected <<<"$row"
  name="${prefix}-${id}"
  escaped="$(dnssd_escape "$expected")"
  registered=0
  for _ in $(seq 1 30); do
    while IFS=';' read -r event _ _ service type _ _ _ service_port _; do
      if [[ "$event" == = && "$service" == "$escaped" && "$type" == _ipps-system._tcp && "$service_port" == "$instance_port" ]]; then
        registered=1
      fi
    done < <(podman exec "$name" avahi-browse --terminate --parsable --resolve _ipps-system._tcp 2>/dev/null || true)
    ((registered)) && break
    sleep 1
  done
  if ((!registered)); then
    podman exec "$name" avahi-browse --terminate --parsable --resolve _ipps-system._tcp >&2 || true
    fail "$name: '$expected' is not advertised for DNS-SD on port $instance_port"
  fi
  echo "  ok: $name advertises '$expected' as _ipps-system._tcp on port $instance_port"
done

echo "== Refused configurations =="
expect_refusal "a PRINTER_APP_INSTANCE without a usable character" \
  'PRINTER_APP_INSTANCE must contain at least one letter, digit or underscore' -e 'PRINTER_APP_INSTANCE= -!- '
expect_refusal "PORT=0" 'PORT must be between 1 and 65535' -e PORT=0
expect_refusal "PORT=65536" 'PORT must be between 1 and 65535' -e PORT=65536
expect_refusal "an overlong PORT" 'PORT must be between 1 and 65535' -e PORT=18446744073709551617

# A fresh bind mount owned by the invoking user is owned by root inside a
# rootless container, so the image user cannot write it.
new_state_dir
unwritable="$state_dir"
chmod 0755 "$unwritable"
expect_refusal "an unwritable state volume" 'podman unshare chown -R 65532:65532 <state-dir>' \
  -v "$unwritable:/var/lib/ps-printer-app:Z"
# A writable root with an unwritable part of the layout would still lose state.
new_state_dir
partial="$state_dir"
chmod 0777 "$partial"
mkdir -m 0755 "$partial/ppd"
expect_refusal "a state volume with an unwritable ppd/" 'podman unshare chown -R 65532:65532 <state-dir>' \
  -v "$partial:/var/lib/ps-printer-app:Z"

printf 'PASS: %s runs isolated instances and refuses invalid instance, port and state configurations\n' "$image"
