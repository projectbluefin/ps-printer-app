kind: stack
description: Core PostScript Printer Application appliance stack.

# CUPS, cups-filters, libcupsfilters and libppd are referenced only through the
# freedesktop-sdk junction, which owns and builds them. No element in this
# repository installs libcups, so the graph has exactly one CUPS owner.
depends:
  - printer-app/application.bst
  - printer-app/runtime-files.bst
  - freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
  - freedesktop-sdk.bst:components/avahi.bst
  - freedesktop-sdk.bst:components/ca-certificates.bst
  - freedesktop-sdk.bst:components/catatonit.bst
  - freedesktop-sdk.bst:components/cups-daemon-only.bst
  - freedesktop-sdk.bst:components/cups-filters.bst
  - freedesktop-sdk.bst:components/dbus.bst
  - freedesktop-sdk.bst:components/ghostscript.bst
  - freedesktop-sdk.bst:components/libcupsfilters.bst
  - freedesktop-sdk.bst:components/libppd.bst
  - freedesktop-sdk.bst:components/tzdata.bst
