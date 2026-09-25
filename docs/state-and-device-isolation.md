# Persistent state, instance isolation and USB access

The appliance keeps everything it persists in one writable volume, advertises
itself under a name that identifies the instance, and reaches a USB printer
through the host's device nodes. This document is the contract for all three,
and it says plainly which parts have been verified and which have not.

## The state volume

The container runs as the unprivileged numeric user `_daemon_` (UID/GID
584792). `/var/lib/ps-printer-app` is the only place it writes, and
`/scripts/prepare-state.sh` prepares it before the application starts:

| Path | Holds |
| --- | --- |
| `/var/lib/ps-printer-app/ps-printer-app.state` | The configured printers and their settings |
| `/var/lib/ps-printer-app/ppd/` | PPD files uploaded through the web interface |
| `/var/lib/ps-printer-app/cups/` | CUPS backend configuration (`snmp.conf`) and the CUPS SSL directory |
| `/var/lib/ps-printer-app/ps-printer-app.log` | The application log |
| `/var/spool/ps-printer-app/` | The job spool |

Mount it to keep that state across container replacement:

```sh
mkdir -p .state/ps-printer-app
podman unshare chown -R 584792:584792 .state/ps-printer-app
podman run --rm --name ps-printer-app \
  --network host \
  -e PORT=18080 \
  -v "$PWD/.state/ps-printer-app:/var/lib/ps-printer-app:Z" \
  ps-printer-app:latest
```

The spool at `/var/spool/ps-printer-app` sits outside the state volume, so
queued jobs do not survive container replacement unless you mount that path
too. The configured printers and their settings do, because they live in the
state file.

The mount has to be writable by UID 584792. A fresh `docker volume create`
volume, and a bind mount owned by another host user, are not: the application
would start, fail to save its state, and lose every configured printer at the
next restart. The launcher refuses to start instead and prints the `chown` that
fixes it, so the failure is visible at boot rather than at the next restart.

Nothing in the launcher replaces a value that is already in the volume. The
layout is created only when it is missing, and `cups/snmp.conf` is seeded from
the image once. An edit - including an empty file - survives a restart and an
image upgrade.

Each path can be pointed somewhere else with `STATE_DIR`, `STATE_FILE`,
`SPOOL_DIR`, `USER_PPD_DIR`, `CUPS_SERVERROOT` and `PPD_PATHS`; the launcher
honours any of them that is already set.

## Two instances on one network

Two Printer Applications on the same LAN have to differ in two things, or one
of them becomes unreachable.

**The port.** `PORT` selects the listening port. Without it the application
starts on 8000, or the next free port. Give each instance its own:

```sh
-e PORT=18080   # first instance
-e PORT=18081   # second instance
```

**The advertised name.** PAPPL registers the system name as the DNS-SD service
instance name and registers it with no auto-rename, so two instances that
advertise the same name cannot coexist: the first registration wins, the second
is refused, and the printers behind it stop being discoverable. Set
`PRINTER_APP_INSTANCE` to give an instance an advertisement of its own:

```sh
-e PRINTER_APP_INSTANCE=lab-a   # advertises "PostScript Printer Application (lab-a)"
-e PRINTER_APP_INSTANCE=lab-b   # advertises "PostScript Printer Application (lab-b)"
```

The value is reduced to letters, digits, hyphens and underscores, capped at 24
characters (Avahi rejects a service name of 63 bytes or more, and the
advertisement wraps the identity), and rejected if nothing usable is left.
Leaving it unset advertises exactly the name the image has always used, so a
single-instance deployment is unaffected.

Two consequences worth knowing:

- The system name also titles the web interface, so each instance shows its own
  name in the browser tab. That is how you tell two open tabs apart.
- The name is saved in the state file and restored from it on the next start,
  so an instance that already has a state volume keeps the name it had. To
  rename an existing instance, start it from a fresh volume or remove the
  `DNSSDName` line from the state file.

Browsing is already narrowed so that one printer is not discovered once per
service type: `patches/cups-dnssd-backend-socket-only.patch` restricts the CUPS
DNS-SD backend to `_pdl-datastream._tcp`. That is about what the appliance
*looks for*; `PRINTER_APP_INSTANCE` is about what it *advertises*.

## USB access without root

The CUPS USB backend opens `/dev/bus/usb/<bus>/<device>` for reading **and
writing**, so the device node has to exist in the container and the container
user has to be able to open it for writing.

The image sets the setuid bit on the USB backend. That grants nothing here: the
container has no privilege for it to elevate to, and under rootless Podman or
Docker the setuid bit does not reach the host's device permissions. Device
access comes from the host.

On the host, check what the node allows:

```sh
ls -l /dev/bus/usb/*/*
```

Printer-class nodes are normally mode `0666`, which is enough. If the node is
not world-writable, add a udev rule that grants the group and add that group to
the container, rather than widening the node or running privileged.

In the container, pass the device through **writable**. A read-only mount of
`/dev/bus/usb` cannot be claimed or written to, so `-v /dev/bus/usb:/dev/bus/usb:ro`
does not give a working USB printer:

```sh
podman run --rm --name ps-printer-app \
  --network host \
  -e PORT=18080 \
  -v "$PWD/.state/ps-printer-app:/var/lib/ps-printer-app:Z" \
  --device /dev/bus/usb \
  --group-add keep-groups \
  ps-printer-app:latest
```

Do not validate USB printing with `--privileged` or `sudo docker`. Both hide
the access model the image actually ships, so a success there says nothing
about a rootless deployment.

USB quirk tables are read from `$USB_QUIRK_DIR/usb`, falling back to the CUPS
data directory in the image.

## Verification status

**Verified here.** `python3 -m unittest discover -s tests -v` runs the shipped
scripts against a temporary state tree and a stub application. It covers the
state layout and its export, that an existing state file and an edited
`snmp.conf` survive a restart, that an unwritable volume is refused with the
fix, that the default advertisement is the string compiled into the
application, that two instances get different advertised names and ports, that
an identity is sanitized into a legal DNS label, that a port that is not a
number or is outside 1-65535 is refused before the application starts, and that
the image ships the launcher helpers and the state layout the launcher expects.
`shellcheck scripts/*.sh` runs over the launcher.

**Not verified here.** This work was written without a container runtime and
without printer hardware. None of the following has been observed:

- The OCI image building or running, on either architecture.
- Two containers actually advertising on one LAN, and how the two
  `avahi-daemon` processes in host-network containers interact.
- DNS-SD discovery of an appliance from another host.
- A USB device being enumerated, claimed, or printed to.
- Physical paper output, and anything about a specific printer's firmware,
  media handling or colour.

Record those only after testing them on real hardware, and never record a
synthetic pass as physical validation.
