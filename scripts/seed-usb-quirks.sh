#!/bin/sh
# Hydrate the persistent USB quirk directory from the tables the image ships.
#
# Source this before starting the application, from a shell that keeps the
# exported USB_QUIRK_DIR for the application and its CUPS backend children:
#
#     . /scripts/seed-usb-quirks.sh
#
# CUPS appends "/usb" to USB_QUIRK_DIR (see backend/usb-libusb.c), so the
# variable names the state directory, not the table directory itself.
#
# Sources are tried in precedence order and the first directory that holds a
# given table wins. Both directories are overridable so the same seeder works
# on the Rockcraft image, the freedesktop-sdk image and the Snap:
#
#     $CUPS_DATADIR/usb  - where the distribution's CUPS installs its tables
#     $BACKEND_DIR       - where the Rockcraft/Snap recipes stage the tables
#                          next to the backends they build
export USB_QUIRK_DIR="${STATE_DIR:-/var/lib/ps-printer-app}"
quirk_target_dir="$USB_QUIRK_DIR/usb"
mkdir -p "$quirk_target_dir"

seed_quirks_from() {
    for quirk_source in "$1"/*.usb-quirks; do
        [ -f "$quirk_source" ] || continue
        quirk_name="${quirk_source##*/}"
        quirk_target="$quirk_target_dir/$quirk_name"
        # A file, an empty file or a dangling symlink in the state volume is a
        # user override. Never overwrite it, so an edit survives a restart and
        # an image upgrade, and never follow a symlink out of the volume.
        if [ -e "$quirk_target" ] || [ -L "$quirk_target" ]; then
            continue
        fi
        cp "$quirk_source" "$quirk_target" || return 1
    done
}

seed_quirks_from "${CUPS_DATADIR:-/usr/share/cups}/usb"
seed_quirks_from "${BACKEND_DIR:-/usr/lib/ps-printer-app/backend}"

unset -f seed_quirks_from
unset quirk_source quirk_name quirk_target quirk_target_dir
