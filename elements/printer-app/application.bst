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
  - fsdk-containers.bst:freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst

# CUPS, cups-filters, libcupsfilters, libppd, ghostscript, PAPPL and
# pappl-retrofit all come from the shared fsdk-containers printing base, the
# one CUPS provider for every printer application.
depends:
  - fsdk-containers.bst:printing/base.bst

config:
  build-commands:
    - make clean
    - make -j2 VERSION="$(cat VERSION)" LDFLAGS="$LDFLAGS -ljpeg"
  install-commands:
    # unitdir is cleared because the OCI appliance supervises the application
    # through the container entrypoint rather than a systemd unit.
    - make DESTDIR="%{install-root}" VERSION="$(cat VERSION)" LDFLAGS="$LDFLAGS -ljpeg" unitdir= install
    # TESTPAGE (testpage.pdf) is resolved from TESTPAGE_DIR; pappl-retrofit
    # ships the page for its legacy-printer-app.
    - install -D -m 0644 /usr/share/legacy-printer-app/testpage.pdf "%{install-root}/usr/share/ps-printer-app/testpage.pdf"
