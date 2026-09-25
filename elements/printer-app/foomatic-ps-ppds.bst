kind: manual
description: Pack the PostScript-only Foomatic manufacturer PPDs into a pyppd archive.

build-depends:
  - printer-app/pyppd.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/findutils.bst
  - fsdk-containers.bst:printing/foomatic-db.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/gzip.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/perl.bst

# The same selection the Rockcraft foomatic-db part makes: PostScript
# manufacturer PPDs only, with the two header typos pyppd and PAPPL reject
# fixed in place. FSDK installs the PPDs gzip-compressed.
config:
  build-commands:
    - |
      mkdir -p PPD
      cp -a /usr/share/foomatic/db/source/PPD/. PPD/
      rm -rf PPD/*/PDF PPD/*/PXL PPD/*/PCL5
      find PPD -type f -name '*.ppd.gz' -exec gunzip {} +
      find PPD -type f ! -name '*.ppd' -delete
      find PPD -type f -exec chmod 0644 {} +
      find PPD -name '*.ppd' -exec perl -p -i -e 's/^\*CloseUI(\s+)/*CloseUI:\1/; s/\*1284DeviceId/*1284DeviceID/' {} +
      pyppd -v -o foomatic-ps-ppds PPD
  install-commands:
    - install -D -m 0755 foomatic-ps-ppds "%{install-root}/usr/share/ppd/foomatic-ps-ppds"
