#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${PORT:-}" ]]; then
  if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
    printf 'PORT must be numeric\n' >&2
    exit 64
  fi
  # Leading zeros are dropped and at most five digits may remain, so the range
  # check reads decimal and cannot wrap around in shell arithmetic.
  if [[ ! "$PORT" =~ ^0*([0-9]{1,5})$ ]] || ((10#${BASH_REMATCH[1]} < 1 || 10#${BASH_REMATCH[1]} > 65535)); then
    printf 'PORT must be between 1 and 65535\n' >&2
    exit 64
  fi
fi

usage_error() {
  printf '%s\n' "$1" >&2
  exit 64
}

config_error() {
  printf '%s\n' "$1" >&2
  exit 78
}

# Web administration knobs (ChairLift ADR-0016). PAPPL serves IPP and the web
# interface on one listener, so on host networking the only boundary around the
# admin pages is authorization. Every value is validated here and the container
# exits non-zero rather than start with a setting the server would silently
# ignore or weaken: pappl-retrofit drops unknown server-options without a
# diagnostic, and PAPPL skips the group check for an admin-group it cannot
# resolve. Exit 64 marks a malformed value; exit 78 marks a value this image
# cannot honour.

# PAPPL server options this appliance forwards. Everything else pappl-retrofit
# understands either weakens the appliance (no-tls, none) or is already the
# default (web-log, web-network, web-security), so it is not accepted.
allowed_server_options=(no-web-interface)
server_options=()
if [[ -n "${PRINTER_APP_SERVER_OPTIONS:-}" ]]; then
  [[ "$PRINTER_APP_SERVER_OPTIONS" =~ ^[a-z-]+(,[a-z-]+)*$ ]] \
    || usage_error 'PRINTER_APP_SERVER_OPTIONS must be a comma-separated list of PAPPL server options'
  IFS=, read -r -a requested_server_options <<< "$PRINTER_APP_SERVER_OPTIONS"
  for option in "${requested_server_options[@]}"; do
    allowed=0
    for candidate in "${allowed_server_options[@]}"; do
      [[ "$option" == "$candidate" ]] && allowed=1
    done
    ((allowed)) || usage_error "PRINTER_APP_SERVER_OPTIONS contains unsupported option '${option}'; supported: ${allowed_server_options[*]}"
    server_options+=("$option")
  done
fi

# Syntax first (exit 64), then what this image can honour (exit 78), so a
# malformed value is diagnosed the same way on any host.
if [[ -n "${PRINTER_APP_AUTH_SERVICE:-}" ]]; then
  [[ "$PRINTER_APP_AUTH_SERVICE" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
    || usage_error 'PRINTER_APP_AUTH_SERVICE must be a PAM service name: letters, digits, "_", "." or "-", not starting with "." or "-"'
fi
if [[ -n "${PRINTER_APP_ADMIN_GROUP:-}" ]]; then
  [[ "$PRINTER_APP_ADMIN_GROUP" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] \
    || usage_error 'PRINTER_APP_ADMIN_GROUP must be a group name: letters, digits, "_", "." or "-", starting with a letter or "_"'
fi

# While the shared printing base builds PAPPL with --disable-libpam, PAPPL
# cannot authenticate users via PAM and forwarding an auth service locks every
# administrator out with 401. Refuse PRINTER_APP_AUTH_SERVICE outright with
# exit 78; set PRINTER_APP_SERVER_OPTIONS=no-web-interface to disable web
# administration instead.
if [[ -n "${PRINTER_APP_AUTH_SERVICE:-}" ]]; then
  config_error "PRINTER_APP_AUTH_SERVICE=${PRINTER_APP_AUTH_SERVICE} cannot be honoured (PAPPL is built without PAM); set PRINTER_APP_SERVER_OPTIONS=no-web-interface to disable web administration instead"
fi

# admin-group only restricts who may administer once auth-service authenticates
# them, and PAPPL treats an unresolvable group as "no group check", so both an
# unset auth service and an unknown group would start unauthenticated.
if [[ -n "${PRINTER_APP_ADMIN_GROUP:-}" ]]; then
  [[ -n "${PRINTER_APP_AUTH_SERVICE:-}" ]] \
    || config_error 'PRINTER_APP_ADMIN_GROUP requires PRINTER_APP_AUTH_SERVICE; a group cannot be enforced without authentication'
  group_known=0
  while IFS=: read -r group_name _; do
    [[ "$group_name" == "$PRINTER_APP_ADMIN_GROUP" ]] && group_known=1
  done < /etc/group
  ((group_known)) \
    || config_error "PRINTER_APP_ADMIN_GROUP=${PRINTER_APP_ADMIN_GROUP} is not a group in this image's /etc/group; PAPPL would skip the group check and admit every authenticated user"
fi

# PAPPL advertises the system name as the DNS-SD service instance name and
# registers it without auto-rename, so two instances with the same name cannot
# coexist on one LAN. PRINTER_APP_INSTANCE names this instance: anything but
# letters, digits, '-' and '_' becomes '-', runs of '-' collapse, the ends are
# trimmed and the result is capped at 24 characters, so the advertised
# "PostScript Printer Application (<id>)" stays well below Avahi's 63-byte
# label limit. Unset passes no system name, so the application keeps its
# built-in SYSTEM_NAME, "PostScript Printer Application".
system_name=""
if [[ -n "${PRINTER_APP_INSTANCE:-}" ]]; then
  instance="${PRINTER_APP_INSTANCE//[^A-Za-z0-9_-]/-}"
  while [[ "$instance" == *--* ]]; do
    instance="${instance//--/-}"
  done
  instance="${instance#-}"
  instance="${instance%-}"
  instance="${instance:0:24}"
  instance="${instance%-}"
  if [[ -z "$instance" ]]; then
    printf 'PRINTER_APP_INSTANCE must contain at least one letter, digit or underscore\n' >&2
    exit 64
  fi
  system_name="PostScript Printer Application ($instance)"
fi

state_dir=/var/lib/ps-printer-app
# The appliance runs as an unprivileged user and cannot repair a state volume
# it does not own. Starting anyway would lose the configured printers at the
# next restart, so refuse and print the fix.
state_error() {
  printf 'The state volume %s is not writable by uid %s.\n' "$state_dir" "$(id -u)" >&2
  printf 'Give it to the image user before starting the container, for example:\n' >&2
  printf '  podman unshare chown -R %s:%s <state-dir>\n' "$(id -u)" "$(id -g)" >&2
  exit 64
}
state_layout=("$state_dir" "$state_dir/ppd" "$state_dir/spool" "$state_dir/usb" "$state_dir/cups" "$state_dir/cups/ssl")
mkdir -p "${state_layout[@]}" 2>/dev/null || state_error
for path in "${state_layout[@]}" "$state_dir/ps-printer-app.state" "$state_dir/ps-printer-app.log"; do
  [[ ! -e "$path" || -w "$path" ]] || state_error
done
mkdir -p /run/dbus /run/avahi-daemon /run/ps-printer-app
# The CUPS SNMP backend reads its configuration from CUPS_SERVERROOT. Seed the
# packaged default when it exists so the appliance also boots when the
# distribution default is absent or the state volume is empty.
if [[ ! -e "$state_dir/cups/snmp.conf" && -e /etc/cups/snmp.conf ]]; then
  cp /etc/cups/snmp.conf "$state_dir/cups/snmp.conf"
fi
# The base's libusb USB backend reads its quirks from $USB_QUIRK_DIR/usb.
# Seed the packaged database once so local edits in the state volume persist.
if [[ ! -e "$state_dir/usb/org.cups.usb-quirks" && ! -L "$state_dir/usb/org.cups.usb-quirks" ]]; then
  cp /usr/share/cups/usb/org.cups.usb-quirks "$state_dir/usb/org.cups.usb-quirks"
fi

# The application reaches CUPS backends and filters through the symlink the
# Makefile installs from /usr/lib/ps-printer-app to the CUPS server binary
# directory, so CUPS keeps its single owner and the appliance keeps its path.
export BACKEND_DIR=/usr/lib/ps-printer-app/backend
export CUPS_SERVERBIN=/usr/lib/ps-printer-app
export CUPS_SERVERROOT="$state_dir/cups"
export FILTER_DIR=/usr/lib/ps-printer-app/filter
export PATH="$FILTER_DIR:$PATH"
export PPD_PATHS="${PPD_PATHS:-/usr/share/ppd/:$state_dir/ppd/}"
export SPOOL_DIR="$state_dir/spool"
export STATE_DIR="$state_dir"
export STATE_FILE="$state_dir/ps-printer-app.state"
export TESTPAGE_DIR=/usr/share/ps-printer-app
export TMPDIR=/tmp
export USB_QUIRK_DIR="$state_dir"

children=()
stop_children() {
  local index pid
  for ((index = ${#children[@]} - 1; index >= 0; index--)); do
    pid="${children[index]}"
    kill -TERM "$pid" 2>/dev/null || true
  done
  wait "${children[@]}" 2>/dev/null || true
}
handle_signal() {
  trap - TERM INT EXIT
  stop_children
  exit 143
}
trap handle_signal TERM INT
trap stop_children EXIT

dbus-daemon --system --nofork --nopidfile &
children+=("$!")
for _ in $(seq 1 30); do
  [[ -S /run/dbus/system_bus_socket ]] && break
  sleep 0.1
done
[[ -S /run/dbus/system_bus_socket ]]

avahi-daemon --no-drop-root --no-chroot &
children+=("$!")
for _ in $(seq 1 30); do
  [[ -f /run/avahi-daemon/pid ]] && break
  sleep 0.1
done
[[ -f /run/avahi-daemon/pid ]]

args=(-o "log-file=$state_dir/ps-printer-app.log")
if [[ -n "${system_name:-}" ]]; then
  args+=(-o "system-name='$system_name'")
fi
if [[ -n "${PORT:-}" ]]; then
  args+=(-o "server-port=$PORT")
fi
if ((${#server_options[@]} > 0)); then
  args+=(-o "server-options=$(IFS=,; printf '%s' "${server_options[*]}")")
fi
if [[ -n "${PRINTER_APP_AUTH_SERVICE:-}" ]]; then
  args+=(-o "auth-service=$PRINTER_APP_AUTH_SERVICE")
fi
if [[ -n "${PRINTER_APP_ADMIN_GROUP:-}" ]]; then
  args+=(-o "admin-group=$PRINTER_APP_ADMIN_GROUP")
fi

web_interface_disabled=0
for option in "${server_options[@]}"; do
  [[ "$option" == no-web-interface ]] && web_interface_disabled=1
done
if [[ -z "${PRINTER_APP_AUTH_SERVICE:-}" ]] && ((!web_interface_disabled)); then
  printf 'NOTICE: web administration is reachable by every client that can reach the IPP port; set PRINTER_APP_SERVER_OPTIONS=no-web-interface to disable it\n' >&2
fi

ps-printer-app "${args[@]}" server &
children+=("$!")

if wait -n "${children[@]}"; then
  status=1
else
  status=$?
fi
stop_children
trap - TERM INT EXIT
exit "$status"
