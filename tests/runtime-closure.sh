#!/usr/bin/env bash
# Inspect a real `bst artifact checkout` of printer-app/core-runtime.bst.
set -euo pipefail
root="${1:?usage: runtime-closure.sh ARTIFACT_DIRECTORY}"
for file in usr/bin/ps-printer-app usr/bin/gs usr/bin/bash \
    usr/share/ppd/generic-ps-printer.ppd usr/share/ps-printer-app/testpage.ps \
    usr/lib/cups/filter/pstops usr/lib/cups/backend/socket usr/lib/cups/backend/usb; do
    test -e "$root/$file"
done
test -x "$root/usr/bin/ps-printer-app"

# The application reaches the CUPS server binaries through the symlink the
# Makefile installs, so a relocated directory would break every filter lookup.
test "$(readlink "$root/usr/lib/ps-printer-app")" = /usr/lib/cups

# No compiler and no package manager in the staged closure.
for command in cc gcc g++ clang make apt apt-get dpkg rpm dnf; do
    for directory in usr/bin usr/sbin bin sbin; do
        test ! -e "$root/$directory/$command"
    done
done

# One actual libcups implementation; SONAME and linker symlinks do not count.
mapfile -t cups < <(find "$root/usr/lib" -type f -name 'libcups.so.*')
if [[ ${#cups[@]} != 1 ]]; then
    printf 'FAIL: expected one libcups implementation, found %s\n' "${#cups[@]}" >&2
    printf '%s\n' "${cups[@]}" >&2
    exit 1
fi

echo 'OK: staged runtime contains the application, Ghostscript, CUPS and a shell without build tools'
