kind: stack
description: Core PostScript Printer Application appliance stack.

# CUPS, cups-filters, libcupsfilters, libppd, ghostscript, avahi-printing,
# PAPPL and pappl-retrofit come from the shared fsdk-containers printing base,
# the one CUPS provider. Never add components/avahi.bst next to it: both
# install avahi-daemon.
depends:
  - printer-app/application.bst
  - printer-app/foomatic-ps-ppds.bst
  - printer-app/hplip-ps.bst
  - printer-app/runtime-files.bst
  - fsdk-containers.bst:printing/base.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/ca-certificates.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/catatonit.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/dbus.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/grep.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/python3.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/tzdata.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/xz.bst
