# Persistent state, instance isolation and USB access

The FSDK OCI image (`ghcr.io/projectbluefin/ps-printer-app`) keeps everything
it persists in one writable volume, advertises itself under a name that
identifies the instance, and reaches a USB printer through the host's device
nodes. This document is the contract for all three, and it says plainly which
parts have been verified and which have not.

The launcher is `files/container-entrypoint.sh`, installed by
`elements/printer-app/runtime-files.bst` as
`/usr/libexec/ps-printer-app/container-entrypoint` and started by `catatonit`
(`elements/oci/ps-printer-app.bst`). It rejects a bad configuration with exit
status 64 before any daemon starts.

## The state volume

The container runs as `nonroot` (UID/GID 65532). `/var/lib/ps-printer-app` is
the only place it writes, and the entrypoint prepares it before the
application starts:

| Path | Holds |
| --- | --- |
| `ps-printer-app.state` | The configured printers, their settings and the advertised names |
| `ppd/` | PPD files uploaded through the web interface |
| `spool/` | The job spool |
| `cups/` | `CUPS_SERVERROOT`: the CUPS SNMP backend's `snmp.conf` and the SSL directory |
| `usb/org.cups.usb-quirks` | The USB backend's quirks database (`USB_QUIRK_DIR`) |
| `ps-printer-app.log` | The application log |

Mount it to keep that state across container replacement, and give it to the
image user first:

```sh
mkdir -p state-a
podman unshare chown -R 65532:65532 state-a
podman run -d --name ps-printer-app-a \
  --network host \
  -e PORT=18080 \
  -v "$PWD/state-a:/var/lib/ps-printer-app:Z" \
  ghcr.io/projectbluefin/ps-printer-app:<version>
```

A bind mount owned by the invoking user belongs to root inside a rootless
container, so UID 65532 cannot write it: the application would start, fail to
save its state, and lose every configured printer at the next restart. The
entrypoint refuses to start instead when the volume, any directory of the
layout above, or an existing state or log file is not writable, and prints the
`podman unshare chown -R 65532:65532 <state-dir>` that fixes it.

Nothing in the entrypoint replaces a value that is already in the volume. The
layout is created only where it is missing, and `cups/snmp.conf` and the USB
quirks are seeded from the image once, so an edit survives a restart and an
image upgrade. `PPD_PATHS` may be set to change the PPD search path; the other
paths are fixed.

## Several instances on one host

Each Printer Application on one host or LAN needs its own **port**, its own
**state volume** and its own **advertised name**, or one of them becomes
unreachable.

**The port.** `PORT` selects the listening port on the host network. It must
be a number from 1 to 65535. Without it the application starts on 8000, or the
next free port.

**The state volume.** Two instances sharing one volume would overwrite each
other's state file. Give each its own directory.

**The advertised name.** The system name is the DNS-SD service instance name
the appliance registers (`_ipps-system._tcp` and `_http._tcp`) and the title
of its web interface. With two instances advertising the same name, only the
first registration is visible; the second is not advertised at all (observed
with two containers on one host). `PRINTER_APP_INSTANCE` gives an instance a
name of its own:

```sh
-e PORT=18080 -e PRINTER_APP_INSTANCE=lab-a   # "PostScript Printer Application (lab-a)"
-e PORT=18081 -e PRINTER_APP_INSTANCE=lab-b   # "PostScript Printer Application (lab-b)"
```

Anything but letters, digits, `-` and `_` becomes `-`, runs of `-` collapse,
the ends are trimmed and the identity is capped at 24 characters, which keeps
the advertised name well below Avahi's 63-byte label limit. A value with
nothing usable left is refused with 64. Leaving it unset keeps the built-in
name, `PostScript Printer Application`.

Two consequences worth knowing:

- PAPPL saves the advertised name as `DNSSDName` in the state file and
  restores it on the next start. Changing `PRINTER_APP_INSTANCE` on an existing
  volume changes the web interface title and the IPP `system-name`, but the
  instance keeps advertising the name it had. To rename it for DNS-SD, start
  from a fresh volume or remove the system's `DNSSDName` line from the state
  file while the container is stopped.
- Printers are advertised (`_ipp._tcp`) under their own names, which are also
  saved in each state file. Give printers in different instances different
  names too.

Browsing is narrowed separately, so that one printer is not discovered once per
service type: `patches/cups-dnssd-backend-socket-only.patch` restricts the CUPS
DNS-SD backend to `_pdl-datastream._tcp`. That is about what the appliance
*looks for*; `PRINTER_APP_INSTANCE` is about what it *advertises*.

## Securing or disabling web administration

The web admin interface shares the host-network port with IPP (see "Several
instances on one host" above), so anything that can reach the port can reach
it. Three environment variables, validated by the entrypoint before any
daemon starts, cover ChairLift ADR-0016's enable condition:

- `PRINTER_APP_SERVER_OPTIONS=no-web-interface` turns the web interface off;
  IPP printing is unaffected. This image ships no configurable PAM stack, so
  it is the only option verified end to end today.
- `PRINTER_APP_AUTH_SERVICE=<name>` sets PAPPL's `auth-service`. Because PAPPL
  is built without PAM in this image, any service name is refused at startup
  until the base graph ships PAM support.
- `PRINTER_APP_ADMIN_GROUP=<group>` is reserved for PAPPL's `admin-group`; the
  entrypoint refuses to start if the group does not resolve or if auth-service
  is unset. Since auth-service is itself refused until the base graph ships PAM
  support, an admin group cannot start this image either.

`PRINTER_APP_SERVER_OPTIONS` also accepts any comma-separated combination of
PAPPL's other server options (`none`, `dnssd-host`, `no-multi-queue`,
`raw-socket`, `usb-printer`, `web-log`, `web-network`, `web-remote`,
`web-security`, `no-tls`); anything else is refused with 64 instead of being
silently ignored by the server. `web-log` together with `no-web-interface` is
also refused with 64, because PAPPL registers the unauthenticated `/logs` and
`/logfile.txt` pages for `web-log` even when the web interface is off.

## USB access without root

The CUPS USB backend (`/usr/lib/cups/backend/usb`, reached through
`/usr/lib/ps-printer-app/backend`) opens `/dev/bus/usb/<bus>/<device>` for
reading **and writing**, so the device node has to exist in the container and
UID 65532 has to be able to open it for writing. The backend is not setuid,
and the image has no privilege to grant: device access comes from the host.

On the host, check what the node allows:

```sh
ls -l /dev/bus/usb/*/*
```

If the node is not writable by everyone, add a udev rule that grants a group
access to that printer, and keep that group in the container, rather than
widening every node or running privileged.

In the container, pass the device through **writable**, either the one device
with `--device` or the whole bus directory with `-v /dev/bus/usb:/dev/bus/usb`.
The upstream Rock examples mount `/dev/bus/usb:ro`; that has not been tried
with this image, so do not rely on it:

```sh
podman run -d --name ps-printer-app-a \
  --network host \
  -e PORT=18080 \
  -e PRINTER_APP_INSTANCE=lab-a \
  -v "$PWD/state-a:/var/lib/ps-printer-app:Z" \
  --device /dev/bus/usb/001/004 \
  --group-add keep-groups \
  ghcr.io/projectbluefin/ps-printer-app:<version>
```

`--group-add keep-groups` (Podman with crun) keeps the invoking user's
supplementary groups, so a group that udev grants on the host also applies in
the container. Give each device to one instance only: two instances that both
see a printer would both try to claim it.

Do not validate USB printing with `--privileged` or `sudo podman`. Both hide
the access model the image actually ships, so a success there says nothing
about a rootless deployment.

## Verification status

**Verified against the built image.** `tests/instance-isolation.sh` (run by
`just verify`) starts two instances on the host network with distinct `PORT`,
state volume and `PRINTER_APP_INSTANCE`, and checks that both serve, report
distinct sanitized names over IPP Get-System-Attributes and in the web
interface, and each advertise their own name as `_ipps-system._tcp` on their
own port; that an instance without `PRINTER_APP_INSTANCE` keeps the built-in
name; and that an instance name with nothing usable, a `PORT` outside 1-65535
and an unwritable state volume (or part of its layout) are refused with 64;
and that a malformed or unavailable `PRINTER_APP_AUTH_SERVICE`, a malformed
or unresolvable `PRINTER_APP_ADMIN_GROUP`, an unrecognized
`PRINTER_APP_SERVER_OPTIONS` value, and `web-log` combined with `no-web-interface`
are each refused with 64. It also starts an
instance with `PRINTER_APP_SERVER_OPTIONS=no-web-interface` and checks that a
printer can still be added over IPP and answers Get-Printer-Attributes while
`/`, `/addppd`, `/logs`, `/logfile.txt` and the printer's `/…/device` page
answer 404 — the same printer
and the first three paths answer 200 on an instance with the web interface, so the 404 is the
removal of those pages and not a wrong URL.
`tests/core-appliance.sh` covers the state layout, seeding, preservation of
edited state across runs, and a non-numeric `PORT`; `tests/core-payload.sh`
covers a configured printer surviving a restart; `tests/usb-quirks.sh`
covers the USB quirk table: that the file seeded at `$USB_QUIRK_DIR/usb` is the
packaged default the image ships at `/usr/share/cups/usb/org.cups.usb-quirks`,
and that a user edit of it survives a restart.

**Not verified.** No printer hardware is available. None of the following has
been observed:

- DNS-SD discovery of an appliance from another host on the LAN.
- A USB device being enumerated, claimed, or printed to, with `--device`,
  a writable or read-only `/dev/bus/usb` mount, or `--group-add keep-groups`.
- Physical paper output, and anything about a specific printer's firmware,
  media handling or colour.
- A successful authenticated admin request against a real PAM service (only
  the refusal path is verified today; no PAM stack is shipped in the image).

Record those only after testing them on real hardware, and never record a
synthetic pass as physical validation.
