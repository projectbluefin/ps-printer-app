kind: manual
description: Build the PostScript Printer Application executable.

sources:
  - kind: local
    path: Makefile
  - kind: local
    path: ps-printer-app.c
  - kind: local
    path: ps-printer-app.1
  - kind: local
    path: ps-printer-app.service
  - kind: local
    path: generic-ps-printer.ppd
  - kind: local
    path: testpage.ps
  - kind: local
    path: VERSION

build-depends:
  - freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst

depends:
  - printer-app/pappl-retrofit.bst
  - freedesktop-sdk.bst:components/ghostscript.bst

config:
  build-commands:
    - make clean
    - make -j2 VERSION="$(cat VERSION)" LDFLAGS="$LDFLAGS -ljpeg"
  install-commands:
    # unitdir is cleared because the OCI appliance supervises the application
    # through the container entrypoint rather than a systemd unit.
    - make DESTDIR="%{install-root}" VERSION="$(cat VERSION)" LDFLAGS="$LDFLAGS -ljpeg" unitdir= install
