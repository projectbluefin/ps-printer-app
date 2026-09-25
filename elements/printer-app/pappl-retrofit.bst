kind: manual
description: Build pappl-retrofit against the single freedesktop-sdk CUPS stack.

sources:
  - kind: git_repo
    url: github:OpenPrinting/pappl-retrofit.git
    track: master
    ref: 1626b338fc8b92a99c2c1a483ac39c739d71b305

build-depends:
  - freedesktop-sdk.bst:public-stacks/buildsystem-autotools.bst

depends:
  - printer-app/pappl.bst
  - freedesktop-sdk.bst:components/cups.bst
  - freedesktop-sdk.bst:components/libcupsfilters.bst
  - freedesktop-sdk.bst:components/libppd.bst

config:
  configure-commands:
    - ./autogen.sh
    - ./configure --prefix=/usr --libdir="%{libdir}"
  build-commands:
    - make -j2
  install-commands:
    - make DESTDIR="%{install-root}" install
