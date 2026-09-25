#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${PORT:-}" && ! "$PORT" =~ ^[0-9]+$ ]]; then
  printf 'PORT must be numeric\n' >&2
  exit 64
fi

state_dir=/var/lib/ps-printer-app
mkdir -p "$state_dir/ppd" "$state_dir/spool" "$state_dir/usb" "$state_dir/cups/ssl" \
  /run/dbus /run/avahi-daemon /run/ps-printer-app
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
if [[ -n "${PORT:-}" ]]; then
  args+=(-o "server-port=$PORT")
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
