kind: manual
description: Build PAPPL for the PostScript Printer Application.

# The version follows this repository's own source contract
# (snap/snapcraft.yaml). The canonical patch in patches/pappl applies cleanly
# to both this release and the release the Ghostscript appliance pins, so a
# future version bump through the dependency automation needs no patch change.
sources:
  - kind: git_repo
    url: github:michaelrsweet/pappl.git
    track: v1.4.*
    ref: v1.4.9-0-gae1889822d872eddd572a43ad0a4a3674fa5a9fa
  - kind: patch_queue
    path: patches/pappl

build-depends:
  - freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst

depends:
  - freedesktop-sdk.bst:components/avahi-libs.bst
  - freedesktop-sdk.bst:components/cups.bst
  - freedesktop-sdk.bst:components/gnutls.bst
  - freedesktop-sdk.bst:components/jpeg.bst
  - freedesktop-sdk.bst:components/libpng.bst
  - freedesktop-sdk.bst:components/libusb.bst

config:
  configure-commands:
    - |
      ./configure \
        --prefix=/usr \
        --libdir="%{libdir}" \
        --disable-libpam \
        --disable-static \
        --enable-shared \
        --enable-libjpeg \
        --enable-libpng \
        --enable-libusb \
        --with-dnssd=avahi \
        --with-tls=gnutls \
        --with-papplstatedir=/var/lib/ps-printer-app \
        --with-papplsockdir=/run/ps-printer-app
  build-commands:
    - make -j2
  install-commands:
    - make DESTDIR="%{install-root}" install
