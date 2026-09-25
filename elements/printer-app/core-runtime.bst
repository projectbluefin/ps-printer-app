kind: compose
description: Compose the shell-enabled Printer Application runtime.

build-depends:
  - printer-app/core-stack.bst

config:
  exclude:
    - debug
    - devel
    - doc
    - locale
    - static-blocklist
    - tests
    - vm-only
