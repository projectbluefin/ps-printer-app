kind: manual
description: Build the pyppd self-extracting PPD archive generator.

sources:
  - kind: git_repo
    url: github:OpenPrinting/pyppd.git
    track: release-*
    ref: release-1-1-0-0-g29ccf6cf85781315a696774e7458a2f1f61aac57

build-depends:
  - fsdk-containers.bst:freedesktop-sdk.bst:public-stacks/buildsystem-python-setuptools.bst

depends:
  - fsdk-containers.bst:freedesktop-sdk.bst:components/python3.bst
  - fsdk-containers.bst:freedesktop-sdk.bst:components/xz.bst

config:
  build-commands:
    - python3 -m build --no-isolation --wheel --outdir dist .
  install-commands:
    - python3 -m installer dist/*.whl --destdir "%{install-root}"
