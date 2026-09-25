#!/bin/sh
# Resolve the name that identifies this Printer Application instance.
#
# Source this before starting the application, from a shell that keeps the
# exported variables for the application and its children:
#
#     . /scripts/instance-name.sh
#
# PAPPL advertises the system name as the DNS-SD service instance name and
# registers it with no auto-rename, so two instances that advertise the same
# name cannot coexist on one LAN: the first registration wins, the second is
# refused, and the printers behind it become undiscoverable. Setting
# PRINTER_APP_INSTANCE gives each instance an advertisement of its own, next to
# the port it already gets from PORT.
#
# Leave PRINTER_APP_INSTANCE unset for a single instance. The default name is
# the one the image has always advertised, so nothing changes for existing
# deployments.
#
# Exports:
#   PRINTER_APP_INSTANCE          the instance identity, sanitized
#   PRINTER_APP_SYSTEM_NAME       the name used for the DNS-SD advertisement
#   PRINTER_APP_DEFAULT_INSTANCE  the identity that means "not set"

PRINTER_APP_DEFAULT_INSTANCE=ps-printer-app

# One identity has to serve as a DNS-SD service instance name. Avahi rejects a
# service name of 63 bytes or more (AVAHI_LABEL_MAX), and the advertisement
# wraps the identity in "PostScript Printer Application (...)", so cap the
# identity at 24 characters: 30 + 24 + 1 = 55, with room to spare. Keep it to
# characters that need no escaping in a service name as well. Anything else
# becomes a hyphen, runs of hyphens collapse, and the ends are trimmed.
printer_app_sanitize_instance() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-' | tr -s '-' | sed -e 's/^-//' -e 's/-$//' | cut -c1-24
}

printer_app_instance=${PRINTER_APP_INSTANCE:-}
if [ -n "$printer_app_instance" ]; then
    printer_app_instance=$(printer_app_sanitize_instance "$printer_app_instance")
    if [ -z "$printer_app_instance" ]; then
        printf 'Error: PRINTER_APP_INSTANCE must contain at least one letter, digit, hyphen or underscore\n' >&2
        exit 64
    fi
fi
: "${printer_app_instance:=$PRINTER_APP_DEFAULT_INSTANCE}"

PRINTER_APP_INSTANCE=$printer_app_instance
if [ "$PRINTER_APP_INSTANCE" = "$PRINTER_APP_DEFAULT_INSTANCE" ]; then
    PRINTER_APP_SYSTEM_NAME='PostScript Printer Application'
else
    PRINTER_APP_SYSTEM_NAME="PostScript Printer Application ($PRINTER_APP_INSTANCE)"
fi
export PRINTER_APP_INSTANCE PRINTER_APP_SYSTEM_NAME PRINTER_APP_DEFAULT_INSTANCE

unset printer_app_instance
unset -f printer_app_sanitize_instance
