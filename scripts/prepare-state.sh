#!/bin/sh
# Prepare the persistent state volume for the Printer Application.
#
# Source this before starting the application, from a shell that keeps the
# exported variables for the application and its CUPS backend and filter
# children:
#
#     . /scripts/prepare-state.sh
#
# The state volume is the only writable place the appliance owns. The state
# file that holds the configured printers, the user-uploaded PPDs, the spool,
# and the CUPS backend configuration all live under it, so a restart or an
# image upgrade keeps what the user configured. Nothing here replaces a value
# that is already in the volume.
#
# Each path is honoured when it is already set, so a deployment can put the
# volume somewhere else and the tests can use a temporary tree:
#
#     STATE_DIR       state root      (default /var/lib/ps-printer-app)
#     STATE_FILE      state file      (default $STATE_DIR/ps-printer-app.state)
#     SPOOL_DIR       spool           (default /var/spool/ps-printer-app)
#     USER_PPD_DIR    uploaded PPDs   (default $STATE_DIR/ppd)
#     CUPS_SERVERROOT CUPS config     (default $STATE_DIR/cups)
#     PPD_PATHS       PPD search path (default the image's, ending in
#                                      $STATE_DIR/ppd)
#
# Exports all of the above. See docs/state-and-device-isolation.md.

: "${STATE_DIR:=/var/lib/ps-printer-app}"
: "${SPOOL_DIR:=/var/spool/ps-printer-app}"
: "${STATE_FILE:=$STATE_DIR/ps-printer-app.state}"
: "${USER_PPD_DIR:=$STATE_DIR/ppd}"
: "${CUPS_SERVERROOT:=$STATE_DIR/cups}"
: "${PPD_PATHS:=/usr/share/ppd:/usr/share/cups/model:/usr/lib/cups/driver:/usr/share/cups/drv:$STATE_DIR/ppd}"
export STATE_DIR STATE_FILE SPOOL_DIR USER_PPD_DIR CUPS_SERVERROOT PPD_PATHS

# The appliance runs as an unprivileged numeric user and cannot create or
# repair the volume itself. A volume the runtime user cannot write - a fresh
# `docker volume create`, or a bind mount owned by another host user - would
# let the application start and then lose every configured printer at the next
# restart, so refuse to start and print the fix instead.
printer_app_state_error() {
    printf 'Error: cannot prepare the state volume as uid %s: %s\n' "$(id -u)" "$STATE_DIR" >&2
    printf 'Chown it to the runtime user before starting the container, for example:\n' >&2
    printf '  podman unshare chown -R %s:%s <state-dir>\n' "$(id -u)" "$(id -g)" >&2
    printf 'See docs/state-and-device-isolation.md.\n' >&2
    exit 64
}

# The layout is created on every start and is idempotent: an existing directory
# keeps its contents and its permissions.
if ! mkdir -p "$STATE_DIR/ppd" "$CUPS_SERVERROOT/ssl" "$SPOOL_DIR"; then
    printer_app_state_error
fi
if [ ! -w "$STATE_DIR" ] || [ ! -w "$SPOOL_DIR" ]; then
    printer_app_state_error
fi

# Seed the CUPS SNMP configuration once, from wherever the image stages it. An
# existing file - including an empty one - is a user value and is kept, so an
# edit survives a restart and an image upgrade.
if [ ! -e "$CUPS_SERVERROOT/snmp.conf" ]; then
    for printer_app_seed in "${BACKEND_DIR:-/usr/lib/ps-printer-app/backend}/snmp.conf" /etc/cups/snmp.conf; do
        if [ -f "$printer_app_seed" ]; then
            cp "$printer_app_seed" "$CUPS_SERVERROOT/snmp.conf" || printer_app_state_error
            break
        fi
    done
fi

unset printer_app_seed
unset -f printer_app_state_error
