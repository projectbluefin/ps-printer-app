#!/bin/sh
set -eux

# Precheck: Ensure PORT is a number or undefined
if [ -n "${PORT:-}" ]; then
    if ! echo "$PORT" | grep -Eq '^[0-9]+$'; then
        echo "Error: PORT must be a valid number" >&2
        exit 64
    fi
    if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo "Error: PORT must be between 1 and 65535" >&2
        exit 64
    fi
fi

# The helpers live next to this script, so the launcher works from the image
# and from a checkout without a hard-coded path.
printer_app_scripts=$(CDPATH='' cd "$(dirname "$0")" && pwd)

# Wait for avahi-daemon to initialize. Its runtime directory is /run on current
# Ubuntu and /var/run on older layouts, so accept either; AVAHI_PID_FILE
# overrides the search so the launcher can be exercised without a running Avahi.
while true; do
    if [ -f "${AVAHI_PID_FILE:-/var/run/avahi-daemon/pid}" ] ||
       [ -f /run/avahi-daemon/pid ]; then
        echo "avahi-daemon is active. Starting ps-printer-app..."
        break
    fi

    echo "Waiting for avahi-daemon to initialize..."
    sleep 1
done

# Name this instance and prepare its persistent state volume before the server
# and its CUPS children start. The paths are resolved at run time, so shellcheck
# cannot follow them; the helpers are linted on their own.
# shellcheck disable=SC1091
. "$printer_app_scripts/instance-name.sh"
# shellcheck disable=SC1091
. "$printer_app_scripts/prepare-state.sh"

# Start the ps-printer-app server.
#
# The system name is the DNS-SD service instance name, so an instance that sets
# PRINTER_APP_INSTANCE advertises itself under a name of its own instead of
# colliding with another instance on the same network. The log file lives in
# the state volume, so two instances do not share one log and the log survives
# the container. The launcher takes no arguments of its own, so the option list
# can be built in the positional parameters.
set -- -o "log-file=$STATE_DIR/ps-printer-app.log" \
       -o "system-name=$PRINTER_APP_SYSTEM_NAME"
if [ -n "${PORT:-}" ]; then
    set -- "$@" -o "server-port=$PORT"
fi

ps-printer-app "$@" server
