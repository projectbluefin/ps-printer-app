# The freedesktop-sdk printing graph

This repository builds its OCI appliance with BuildStream against
[freedesktop-sdk](https://gitlab.com/freedesktop-sdk/freedesktop-sdk) instead of
staging packages from a build recipe. The graph lives in `project.conf` and
`elements/`, and the entry point is `elements/oci/ps-printer-app.bst`.

## One CUPS artifact owner

CUPS is built by the freedesktop-sdk junction and by nothing else in this
repository. The application, `pappl`, `pappl-retrofit` and the filters all
depend on `freedesktop-sdk.bst:components/cups.bst`, so every reverse dependency
is compiled against the same `libcups` the appliance receives at runtime.

The previous build recipe compiled its own CUPS and copied `libcups.so*` into
the image. Two implementations of `libcups` in one image is the failure this
graph exists to prevent: the application links one copy while a filter loads
another, and the split rules that keep `cups-libs` and `cups-license` intact
disappear. `tests/printing-graph.sh` fails if the graph grows a second provider
or if those split rules go missing.

## The shared patch seam

The appliance needs CUPS behaviour the upstream sources do not have by default.
Those changes are kept as source patches and applied inside the junction, not by
forking the elements:

| Patch | Queued against | Effect |
| --- | --- | --- |
| `patches/cups/cups-dnssd-backend-socket-only.patch` | CUPS | Browse `_pdl-datastream._tcp` only, so discovery does not duplicate the printers the application already owns |
| `patches/cups/cups-usb-quirk-dir.patch` | CUPS | Read USB quirks from `USB_QUIRK_DIR` so the appliance can keep them in writable state |
| `patches/cups-filters/foomatic-rip-option-use-after-free.patch` | cups-filters | Fix a use-after-free in `foomatic-rip` option handling |
| `patches/libcupsfilters/avoid-global-option-lock-after-fork.patch` | libcupsfilters | Avoid a global option lock held after `fork()` in a multi-threaded filter process |
| `patches/pappl/printer-application.patch` | pappl | Raise the vendor-option budget, disable log rotation across forked filters, use the `cups:socket` device scheme, and link with `LDFLAGS` |

These files are the same reviewed patches the Ghostscript appliance carries, and
the Snap and Rock builds apply the CUPS ones from this same directory, so there
is one reviewed copy of each change rather than one derivation per build system.

`patches/freedesktop-sdk/` is applied at the junction project level. It injects
the nested source patch queues above and adjusts freedesktop-sdk's own CUPS,
Avahi and TLS configuration. A project patch is used instead of
`config.overrides` so freedesktop-sdk keeps owning its elements and inherits
upstream updates.

## Building

BuildStream runs inside a pinned builder image, so the host only needs `just`,
`podman` and `fuse3`:

```sh
just fetch     # fetch immutable sources with bounded retries
just build     # build and export the complete local OCI image
just verify    # verify the graph, the patch seam, the closure and the image
```

`just validate` resolves the graph without building it. `ARCH` selects the
architecture for the graph and source checks; both `x86_64` and `aarch64` are
supported, and the application's own closure is architecture-independent.

## What the checks do and do not claim

- `tests/printing-graph.sh` resolves the graph, asserts exactly one CUPS
  provider, asserts the `cups-libs` and `cups-license` split rules survive, and
  asserts the runtime closure contains no compiler, package manager or
  `buildsystem-*` element. With `--sources` it also checks out the pinned
  sources and asserts the shared CUPS patches are present in the checked-out
  CUPS tree and in the patched `pappl` tree.
- `tests/cups-patch-chain.sh` verifies the patch seam specifically: the
  CUPS-dependent element resolves, exactly one private CUPS base provides it,
  and the staged CUPS source carries the DNS-SD and `USB_QUIRK_DIR` changes.
- `tests/runtime-closure.sh` inspects a real artifact checkout: the application,
  Ghostscript and a shell are present, the `usr/lib/ps-printer-app` symlink
  points at the CUPS server binary directory, exactly one `libcups.so.*` exists,
  and no compiler or package manager is staged.
- `just verify` requires `tests/core-appliance.sh` and `tests/core-payload.sh`,
  which drive a real IPP job through the driver, filter and socket backend. It
  fails rather than skipping when they are absent, because a graph check is not
  image validation evidence.

None of these checks print on paper. Physical paper output stays unverified
without printer hardware, and no check in this repository may claim otherwise.

## Known gap: the USB backend does not use libusb

CUPS builds `/usr/lib/cups/backend/usb` on Linux either way, because
`backend/usb.c` falls back to the `usb-unix.c` implementation when
`HAVE_LIBUSB` is not defined. freedesktop-sdk's CUPS is configured without
libusb — `elements/components/_private/cups-base.bst` has no libusb in its
build dependency closure, which is 268 elements and contains no libusb,
usbutils or libgusb — so the appliance ships the `/dev/usb/lp*` implementation
and `patches/cups/cups-usb-quirk-dir.patch`, which changes
`backend/usb-libusb.c`, has no effect on the built binary.

The patch stays in the seam because it is the reviewed shared copy and the
quirk-directory behaviour is what the appliance wants once the backend links
libusb. Making it effective is a CUPS build change, so it belongs with the USB
access and quirk seeding work rather than with the graph.

