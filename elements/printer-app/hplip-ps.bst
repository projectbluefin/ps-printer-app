kind: manual
description: Build the HPLIP hpps filter and pack the HPLIP PostScript PPDs.

sources:
  - kind: git_repo
    url: salsa:printing-team/hplip.v2.git
    track: debian/*
    ref: debian/3.26.4+dfsg0-3-0-gf27f786d5f1060cce7c92e42488bd5e5d00ba135

build-depends:
  - printer-app/pyppd.bst
  - fsdk-containers.bst:printing/base.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/findutils.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/perl.bst

# Only hpps and the PostScript PPDs, as the Rockcraft hplip part does; the
# rest of HPLIP is not part of this application.
#
# hppsfilter.c keeps "not in the PPD" as -1 in plain char and compares it with
# -1 (GetPPDValues/WriteSecurePrinting). char is unsigned on AArch64, so there
# the PIN job's @PJL SET HOLD/HOLDKEY lines were silently dropped; build it
# with the signed char it assumes on every architecture.
config:
  build-commands:
    - |
      cd prnt/hpps
      touch config.h
      cc $CFLAGS -fsigned-char -I. -o hpps *.c $LDFLAGS -lcups
      rm config.h
    - |
      mkdir -p PPD
      cp -a prnt/ps/. PPD/
      find PPD -type f ! -name '*.ppd*' -delete
      find PPD -type f -exec chmod 0644 {} +
      find PPD -name '*.ppd' -exec perl -p -i -e 's/^\*CloseUI(\s+)/*CloseUI:\1/; s/\*1284DeviceId/*1284DeviceID/' {} +
      pyppd -v -o hplip-ps-ppds PPD
  install-commands:
    # /usr/lib/ps-printer-app is the application's symlink to the CUPS
    # server binary directory, so the filter lands where the application
    # looks for it.
    - install -D -m 0755 prnt/hpps/hpps "%{install-root}/usr/lib/cups/filter/hpps"
    - install -D -m 0755 hplip-ps-ppds "%{install-root}/usr/share/ppd/hplip-ps-ppds"
